require 'icalendar'

module Agents
  class RssCalendarAgent < Agent
    include WebRequestConcern

    cannot_be_scheduled!
    cannot_create_events!

    description do
      <<~MD
        Options:

          * `secrets` - An array of tokens that the requestor must provide for light-weight authentication.
          * `expected_receive_period_in_days` - How often you expect data to be received by this Agent from other Agents.
          * `template` - A JSON object representing a mapping between item output keys and incoming event values.  Use [Liquid](https://github.com/huginn/huginn/wiki/Formatting-Events-using-Liquid) to format the values.  Values of the `link`, `title`, `description` and `icon` keys will be put into the \\<channel\\> section of RSS output.  Value of the `self` key will be used as URL for this feed itself, which is useful when you serve it via reverse proxy.  The `item` key will be repeated for every Event.  The `pubDate` key for each item will have the creation time of the Event unless given.
          * `events_to_show` - The number of events to output in RSS or JSON. (default: `40`)
          * `ttl` - A value for the \\<ttl\\> element in RSS output. (default: `60`)
          * `ns_dc` - Add [DCMI Metadata Terms namespace](http://purl.org/dc/elements/1.1/) in output xml
          * `ns_media` - Add [yahoo media namespace](https://en.wikipedia.org/wiki/Media_RSS) in output xml
          * `ns_itunes` - Add [itunes compatible namespace](http://lists.apple.com/archives/syndication-dev/2005/Nov/msg00002.html) in output xml
          * `rss_content_type` - Content-Type for RSS output (default: `application/rss+xml`)
          * `response_headers` - An object with any custom response headers. (example: `{"Access-Control-Allow-Origin": "*"}`)
          * `push_hubs` - Set to a list of PubSubHubbub endpoints you want to publish an update to every time this agent receives an event. (default: none)  Popular hubs include [Superfeedr](https://pubsubhubbub.superfeedr.com/) and [Google](https://pubsubhubbub.appspot.com/).  Note that publishing updates will make your feed URL known to the public, so if you want to keep it secret, set up a reverse proxy to serve your feed via a safe URL and specify it in `template.self`.
      MD
    end

    def default_options
      {
        "secrets" => ["a-secret-key"],
        "expected_receive_period_in_days" => 2,
      }
    end

    def working?
      last_receive_at && last_receive_at > options['expected_receive_period_in_days'].to_i.days.ago && !recent_error_logs?
    end

    def validate_options
      if options['secrets'].is_a?(Array) && options['secrets'].length > 0
        options['secrets'].each do |secret|
          case secret
          when %r{[/.]}
            errors.add(:base, "secret may not contain a slash or dot")
          when String
          else
            errors.add(:base, "secret must be a string")
          end
        end
      else
        errors.add(:base, "Please specify one or more secrets for 'authenticating' incoming feed requests")
      end

      unless options['expected_receive_period_in_days'].present? && options['expected_receive_period_in_days'].to_i > 0
        errors.add(:base,
                   "Please provide 'expected_receive_period_in_days' to indicate how many days can pass before this Agent is considered to be not working")
      end
    end

    def events_to_show
      (interpolated['events_to_show'].presence || 40).to_i
    end

    DEFAULT_EVENTS_ORDER = {
      'events_order' => nil,
      'events_list_order' => [["{{_index_}}", "number", true]],
    }

    def events_order(key = SortableEvents::EVENTS_ORDER_KEY)
      super || DEFAULT_EVENTS_ORDER[key]
    end

    def latest_events(reload = false)
      received_events = received_events().reorder(id: :asc)

      events =
        if (event_ids = memory[:event_ids]) &&
            memory[:events_order] == events_order &&
            memory[:events_to_show] >= events_to_show
          received_events.where(id: event_ids).to_a
        else
          memory[:last_event_id] = nil
          reload = true
          []
        end

      if reload
        memory[:events_order] = events_order
        memory[:events_to_show] = events_to_show

        new_events =
          if last_event_id = memory[:last_event_id]
            received_events.where(Event.arel_table[:id].gt(last_event_id)).to_a
          else
            source_ids.flat_map { |source_id|
              # dig twice as many events as the number of
              # `events_to_show`
              received_events.where(agent_id: source_id)
                .last(2 * events_to_show)
            }.sort_by(&:id)
          end

        unless new_events.empty?
          memory[:last_event_id] = new_events.last.id
          events.concat(new_events)
        end
      end

      events = sort_events(events).last(events_to_show)

      if reload
        memory[:event_ids] = events.map(&:id)
      end

      events
    end

    def receive_web_request(params, method, format)
      unless interpolated['secrets'].include?(params['secret'])
        if format =~ /json/
          return [{ error: "Not Authorized" }, 401]
        else
          return ["Not Authorized", 401]
        end
      end

      source_events = sort_events(latest_events, 'events_list_order').group_by {|e| e.payload["guid"] }

      calendar = Icalendar::Calendar.new.tap do |c|
        source_events.each do |(guid, events)|
          c.event do |e|
            evt = events.max_by {|e| e.payload[:lastUpdated] }
            e.uid = evt.payload[:guid]
            start_time = DateTime.parse(evt.payload[:eventTime])
            e.dtstart = Icalendar::Values::DateTime.new(start_time, 'tzid' => 'Etc/UTC')
            e.dtend = start_time + Rational(3, 48) # 90 minutes
            e.summary = evt.payload[:category]
            e.url = evt.payload[:agenda]
          end
        end
      end

      [calendar.to_ical, 200, "text/calendar"]
    end

    def receive(incoming_events)
      latest_events(true)
    end
  end
end
