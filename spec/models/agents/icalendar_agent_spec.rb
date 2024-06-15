require 'rails_helper'

describe Agents::RssCalendarAgent do
  let(:agent) do
    subject.new(name: "My RSS Calendar Agent").tap do |a|
      a.options = a.default_options.merge('secrets' => ['secret1', 'secret2'], 'events_to_show' => 3)
      a.user = users(:bob)
      a.sources << agents(:bob_website_agent)
      a.save!
    end
  end
end
