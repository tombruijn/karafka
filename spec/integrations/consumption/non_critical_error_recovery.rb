# frozen_string_literal: true

# Karafka should be able to recover from non-critical error with same consumer instance and it
# also should emit an event with error details that can be logged

class Listener
  def on_error_occurred(event)
    DataCollector[:errors] << event
  end
end

Karafka.monitor.subscribe(Listener.new)

setup_karafka(allow_errors: true)

class Consumer < Karafka::BaseConsumer
  def consume
    @count ||= 0
    @count += 1

    messages.each { |message| DataCollector[0] << message.raw_payload }
    DataCollector[1] << object_id

    raise StandardError if @count == 1
  end
end

draw_routes do
  consumer_group DataCollector.consumer_group do
    topic DataCollector.topic do
      consumer Consumer
    end
  end
end

elements = Array.new(5) { SecureRandom.uuid }
elements.each { |data| produce(DataCollector.topic, data) }

start_karafka_and_wait_until do
  # We have 5 messages but we retry thus it needs to be minimum 6
  DataCollector[0].size >= 6
end

assert DataCollector[0].size >= 6
assert_equal 1, DataCollector[1].uniq.size
assert_equal StandardError, DataCollector[:errors].first[:error].class
assert_equal 'consumer.consume.error', DataCollector[:errors].first[:type]
assert_equal 'error.occurred', DataCollector[:errors].first.id
assert_equal 5, DataCollector[0].uniq.size