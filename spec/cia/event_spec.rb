require 'spec_helper'

describe CIA::Event do
  it "has many attribute_changes" do
    change = create_change
    expect(change.event.attribute_changes).to eq([change])
    change.event.destroy
    expect{ change.reload }.to raise_error(ActiveRecord::RecordNotFound)
  end

  context "attribute_change_hash" do
    it "is empty for empty changes" do
      expect(create_event.attribute_change_hash).to eq({})
    end

    it "contains all changes" do
      change = create_change(old_value: "a", new_value: "b")
      change = create_change(attribute_name: "foo", old_value: "b", new_value: nil, event: change.event)
      expect(change.event.attribute_change_hash).to eq("bar" => ["a", "b"], "foo" => ["b", nil])
    end
  end

  context ".previous" do
    it "is sorted id desc" do
      events = [create_event(created_at: 3.days.ago), create_event(created_at: 2.days.ago), create_event(created_at: 1.day.ago)].map(&:id)
      expect(CIA::Event.previous.map(&:id)).to eq(events.reverse)
    end
  end

  context "validations" do
    let(:source_attributes){ {source: nil, source_id: 99999, source_type: "Car"} }

    it "validates source" do
      expect{
        create_event(source_attributes)
      }.to raise_error(ActiveRecord::RecordInvalid, /Source can't be blank/)
    end

    it "does not validates source when action is destroy" do
      create_event(source_attributes.merge(action: "destroy"))
    end

    it "does not validates source when updating" do
      create_event.update!(source_id: 9999)
    end

    it "does not validates source when source_display_name is present" do
      create_event(source: nil, source_id: -111, source_type: 'FakeTypeHere', source_display_name: 'abc')
    end

    it "validates source when source_display_name is blank" do
      expect{
        create_event(source: nil, source_id: -111, source_type: 'FakeTypeHere', source_display_name: '')
      }.to raise_error(NameError, 'uninitialized constant FakeTypeHere')
    end
  end
end
