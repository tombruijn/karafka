# frozen_string_literal: true

# When we have a batch of ActiveJobs jobs and we loose our partition assignment, jobs that
# did not start prior to the revocation should not start at all.

# To simulate this we will jobs on two partitions in parallel and we will "loose" one
# of them and detect this. We need to make consumption jobs long enough to jump with a rebalance
# in the middle. Since we internally mark as consumed on each job, we can be aware of revocation
# early enough

TOPIC = 'integrations_17_02'

setup_karafka do |config|
  config.license.token = pro_license_token
  config.max_wait_time = 2_500
  config.max_messages = 20
  config.concurrency = 4
  config.shutdown_timeout = 60_000
end

setup_active_job

draw_routes do
  consumer_group DataCollector.consumer_group do
    active_job_topic TOPIC do
      virtual_partitioner ->(_) { rand }
    end
  end
end

class Job < ActiveJob::Base
  queue_as TOPIC

  karafka_options(
    dispatch_method: :produce_sync,
    partitioner: ->(job) { job.arguments.first[0] }
  )

  # This job is so slow, that while it is running another consumer joins in and should take over
  # one partition.
  # If this would not happen, we should not stop until all batches of jobs are processed
  def perform(value1)
    DataCollector[:started] << value1
    sleep(20)
    DataCollector[:done] << value1
  end
end

consumer = setup_rdkafka_consumer

# 1 and 4 are picked because they will dispatch messages to 0 and 1 partition
10.times do
  Job.perform_later('1')
  Job.perform_later('4')
end

revoked = false

# This will trigger a rebalance when the first job is being processed
# We keep it alive so we do not trigger a second rebalance
Thread.new do
  sleep(10)

  consumer.subscribe(TOPIC)

  consumer.each do
    unless revoked
      sleep(5)
      revoked = true
    end
  end
end

start_karafka_and_wait_until do
  DataCollector[:started].size >= 4 && revoked
end

assert DataCollector[:started].size < 10
assert DataCollector[:done].size < 10

consumer.close