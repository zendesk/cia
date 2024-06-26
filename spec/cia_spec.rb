require 'spec_helper'

describe CIA do
  it "has a VERSION" do
    expect(CIA::VERSION).to match(/^[\.\da-z]+$/)
  end

  describe ".audit" do
    it "has no transaction when it starts" do
      expect(CIA.current_transaction).to be_nil
    end

    it "starts a new transaction" do
      result = 1
      CIA.audit(a: 1) do
        result = CIA.current_transaction
      end
      expect(result).to eq(a: 1)
    end

    it "stops the transaction after the block" do
      CIA.audit({}){}
      expect(CIA.current_transaction).to be_nil
    end

    it "returns the block content" do
      expect(CIA.audit({}){ 1 }).to eq(1)
    end

    it "is threadsafe" do
      Thread.new do
        CIA.audit({}) do
          sleep 0.04
        end
      end
      sleep 0.01
      expect(CIA.current_transaction).to be_nil
      sleep 0.04 # so next tests dont fail
    end

    it "can nest multiple independent transaction" do
      states = []
      CIA.audit(a: 1) do
        states << CIA.current_transaction
        CIA.audit(b: 1) do
          states << CIA.current_transaction
        end
        states << CIA.current_transaction
      end
      states << CIA.current_transaction
      expect(states).to eq([{a: 1}, {b: 1}, {a: 1}, nil])
    end
  end

  describe ".amend_audit" do
    it "opens a new transaction when none exists" do
      t = nil
      CIA.amend_audit(actor: 111){ t = CIA.current_transaction }
      expect(t).to eq(actor: 111)
    end

    it "amends a running transaction" do
      t = nil
      CIA.amend_audit(actor: 222, ip_address: 123) do
        CIA.amend_audit(actor: 111) { t = CIA.current_transaction }
      end
      expect(t).to eq(actor: 111, ip_address: 123)
    end

    it "returns to old state after transaction" do
      CIA.amend_audit(actor: 222, ip_address: 123) do
        CIA.amend_audit(actor: 111) {  }
      end
      expect(CIA.current_transaction).to be_nil

      CIA.amend_audit(actor: 111) {  }
      expect(CIA.current_transaction).to be_nil
    end
  end

  describe ".record" do
    let(:object) { Car.new }

    around do |example|
      CIA.audit actor: User.create! do
        example.call
      end
    end

    it "tracks create" do
      expect{
        object.save!
      }.to change{ CIA::Event.count }.by(+1)
      expect(CIA::Event.last.action).to eq("create")
    end

    it "tracks delete" do
      object.save!
      expect{
        object.destroy
      }.to change{ CIA::Event.count }.by(+1)
      expect(CIA::Event.last.action).to eq("destroy")
    end

    it "tracks update" do
      object.save!
      expect{
        object.update(wheels: 3)
      }.to change{ CIA::Event.count }.by(+1)
      expect(CIA::Event.last.action).to eq("update")
    end

    it "can override" do
      CIA.amend_audit message: "custom" do
        object.save!
      end
      expect(CIA::Event.last.message).to eq("custom")
    end

    it "does not track failed changes" do
      car = Car.create!(wheels: 1).id
      expect{
        expect{ FailCar.new(wheels: 4).save  }.to raise_error(FailCar::Oops)
        car = FailCar.find(car)
        expect{ car.update(wheels: 2) }.to raise_error(FailCar::Oops)
        expect{ car.destroy }.to raise_error(FailCar::Oops)
      }.to_not change{ CIA::Event.count }
    end

    it "is rolled back if auditing fails" do
      expect(CIA).to receive(:record).and_raise("XXX")
      expect{
        expect{
          CIA.audit{ object.save! }
        }.to raise_error("XXX")
      }.to_not change{ object.class.count }
    end

    it "is ok with non-attribute methods passed into .audit if they are set as non-recordable" do
      CIA.non_recordable_attributes = [:foo]
      expect {
        CIA.audit(actor: User.create!, foo: 'bar') {
          object.save!
        }
      }.to change{ CIA::Event.count }.by(+1)
    end

    context "nested classes with multiple audited_attributes" do
      let(:object){ NestedCar.new }

      it "has the exclusive sub-classes attributes of the nested class" do
        expect(object.class.audited_attributes).to eq(%w(drivers))
      end

      it "does not record twice for nested classes" do
        expect{
          CIA.audit{ object.save! }
        }.to change{ CIA::Event.count }.by(+1)
      end

      it "does not record twice for super classes" do
        expect{
          CIA.audit{ Car.new.save! }
        }.to change{ CIA::Event.count }.by(+1)
      end
    end

    context "nested classes with 1 audited_attributes" do
      let(:object){ InheritedCar.new }

      it "has the super-classes attributes" do
        expect(object.class.audited_attributes).to eq(%w(wheels))
      end

      it "does not record twice for nested classes" do
        expect{
          CIA.audit{ object.save! }
        }.to change{ CIA::Event.count }.by(+1)
      end

      it "does not record twice for super classes" do
        expect{
          CIA.audit{ Car.new.save! }
        }.to change{ CIA::Event.count }.by(+1)
      end
    end

    context "custom changes" do
      let(:object) { CarWithCustomChanges.new }

      it "tracks custom changes" do
        object.save!
        expect{
          object.update(wheels: 3)
        }.to change{ CIA::Event.count }.by(+1)
        expect(CIA::Event.last.action).to eq("update")
        expect(CIA::Event.last.attribute_change_hash).to eq(
          "wheels" => [nil, "3"],
          "foo" => ["bar", "baz"]
        )
      end
    end

    context ":if" do
      let(:object) { CarWithIf.new }

      it "tracks if :if is true" do
        expect{
          object.tested = true
          object.save!
        }.to change{ CIA::Event.count }.by(+1)
        expect(CIA::Event.last.action).to eq("create")
      end

      it "does not track if :if is false" do
        expect{
          object.save!
        }.to_not change{ CIA::Event.count }
        expect(CIA::Event.last).to be_nil
      end
    end

    context ":unless" do
      let(:object) { CarWithUnless.new }

      it "tracks if :unless is false" do
        expect{
          object.save!
        }.to change{ CIA::Event.count }.by(+1)
        expect(CIA::Event.last.action).to eq("create")
      end

      it "does not track if :unless is true" do
        expect{
          object.tested = true
          object.save!
        }.to_not change{ CIA::Event.count }
        expect(CIA::Event.last).to be_nil
      end
    end

    context "events" do
      def parse_event_changes(event)
        event.attribute_changes.map { |c| [c.attribute_name, c.old_value, c.new_value] }
      end

      def no_audit_created!
        event = nil
        expect{
          event = yield
        }.to_not change{ CIA::Event.count }

        expect(event).to be_nil
      end

      it "records attributes in transaction" do
        event = nil
        CIA.audit actor: User.create!, ip_address: "1.2.3.4" do
          event = CIA.record(:destroy, Car.create!)
        end
        expect(event.ip_address).to eq("1.2.3.4")
      end

      it "records attribute creations" do
        source = Car.create!
        source.wheels = 4
        event = CIA.record(:update, source).reload

        expect(parse_event_changes(event)).to eq([["wheels", nil, "4"]])
      end

      it "can act on attributes in before_save" do
        x = nil
        CIA.current_transaction[:hacked_before_save_action] = lambda{|event| x = event.attribute_changes.size }
        source = Car.create!
        source.wheels = 4
        CIA.record(:update, source)
        expect(x).to eq(1)
      end

      it "records multiple attributes" do
        source = CarWith3Attributes.create!
        source.wheels = 4
        source.drivers = 2
        source.color = "red"
        event = CIA.record(:update, source).reload
        expect(parse_event_changes(event)).to eq([["wheels", nil, "4"], ["color", nil, "red"], ["drivers", nil, "2"]])
      end

      it "records attribute changes" do
        source = Car.create!(wheels: 2)
        source.wheels = 4
        event = CIA.record(:update, source).reload
        expect(parse_event_changes(event)).to eq([["wheels", "2", "4"]])
      end

      it "records attribute deletions" do
        source = Car.create!(wheels: 2)
        source.wheels = nil
        event = CIA.record(:update, source).reload
        expect(parse_event_changes(event)).to eq([["wheels", "2", nil]])
      end

      it "does not record unaudited attribute changes" do
        source = Car.create!
        source.drivers = 2
        no_audit_created!{ CIA.record(:update, source) }
      end

      it "records audit_message as message even if there are no changes" do
        source = CarWithAMessage.create!
        source.audit_message = "Foo"
        event = CIA.record(:update, source)

        expect(event.message).to eq("Foo")
        expect(parse_event_changes(event)).to eq([])
      end

      it "does not record after saving with an audit_message" do
        source = CarWithAMessage.create!
        source.audit_message = "Foo"
        CIA.record(:update, source)

        no_audit_created!{ CIA.record(:update, source) }
      end

      it "does not record if it's empty and there are no changes" do
        source = CarWithAMessage.create!
        source.audit_message = "   "
        no_audit_created!{ CIA.record(:update, source) }
      end

      it "record non-updates even without changes" do
        source = Car.create!
        event = CIA.record(:create, source)
        expect(parse_event_changes(event)).to eq([])
      end
    end

    context "exception_handler" do
      before do
        allow($stderr).to receive(:puts)
        allow(CIA).to receive(:current_transaction).and_raise(StandardError.new("foo"))
      end

      def capture_exception
        begin
          old = CIA.exception_handler
          ex = nil
          CIA.exception_handler = lambda{|e| ex = e }
          yield
          ex
        ensure
          CIA.exception_handler = old
        end
      end

      it "raises exceptions by the transaction" do
        ex = nil
        begin
          object.save!
        rescue Object => e
          ex = e
        end
        expect(ex.inspect).to eq('#<StandardError: foo>')
      end

      it "can capture exception via handler" do
        ex = capture_exception do
          object.save!
        end
        expect(ex.inspect).to eq('#<StandardError: foo>')
      end
    end

    context "with after_commit" do
      let(:object){ CarWithTransactions.new(wheels: 1) }

      it "still tracks" do
        expect{
          CIA.audit{ object.save! }
        }.to change{ CIA::Event.count }.by(+1)
        expect(CIA::Event.last.attribute_change_hash).to eq("wheels" => [nil, "1"])
      end

      it "unsets temp-changes after the save" do
        object.save!

        # does not re-track old changes
        expect{
          CIA.audit{ object.update(drivers: 2) }
        }.to change{ CIA::Event.count }.by(+1)
        expect(CIA::Event.last.attribute_change_hash).to eq("drivers" => [nil, "2"])

        # empty changes
        expect{
          CIA.audit{ object.update(drivers: 2) }
        }.to_not change{ CIA::Event.count }
      end

      it "is not rolled back if auditing fails" do
        expect(CIA).to receive(:record).and_raise("XXX")
        begin
          expect{
            CIA.audit{ object.save! }
          }.to change{ object.class.count }.by(+1)
        rescue RuntimeError => e
          # errors from after_commit are never raised in rails 3+
          raise e if e.message != "XXX"
        end
      end
    end
  end

  context ".current_actor" do
    it "is nil when nothing is set" do
      expect(CIA.current_actor).to be_nil
    end

    it "is nil when no actor is set" do
      CIA.audit do
        expect(CIA.current_actor).to be_nil
      end
    end

    it "is the current :actor" do
      CIA.audit actor: 111 do
        expect(CIA.current_actor).to eq(111)
      end
    end
  end

  context ".current_actor=" do
    it "does nothing if no transaction is running" do
      CIA.current_actor = 111
      expect(CIA.current_transaction).to be_nil
    end

    it "sets when transaction is started" do
      CIA.audit actor: 222 do
        CIA.current_actor = 111
        expect(CIA.current_transaction).to eq(actor: 111)
      end
    end
  end
end
