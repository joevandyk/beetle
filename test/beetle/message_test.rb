require File.expand_path(File.dirname(__FILE__) + '/../test_helper')


module Beetle

  class EncodingTest < Test::Unit::TestCase
    test "an exception during decoding should be stored in the exception attribute" do
      header = stub_everything("raising header")
      m = Message.new("queue", header, 'foo')
      assert_instance_of NoMethodError, m.exception
    end

    test "a message should encode/decode the message format version correctly" do
      header = header_with_params({})
      m = Message.new("queue", header, 'foo')
      assert_equal Message::FORMAT_VERSION, m.format_version
    end

    test "a redundantly encoded message should have the redundant flag set on delivery" do
      header = header_with_params(:redundant => true)
      m = Message.new("queue", header, 'foo')
      assert m.redundant?
      assert_equal(Message::FLAG_REDUNDANT, m.flags & Message::FLAG_REDUNDANT)
    end

    test "encoding a message with a specfied time to live should set an expiration time" do
      Message.expects(:now).returns(25)
      header = header_with_params(:ttl => 17)
      m = Message.new("queue", header, 'foo')
      assert_equal 42, m.expires_at
    end

    test "encoding a message should set the default expiration date if none is provided in the call to encode" do
      Message.expects(:now).returns(1)
      header = header_with_params({})
      m = Message.new("queue", header, 'foo')
      assert_equal 1 + Message::DEFAULT_TTL, m.expires_at
    end

    test "the publishing options should include both the beetle headers and the amqp params" do
      key = 'fookey'
      options = Message.publishing_options(:redundant => true, :key => key, :mandatory => true, :immediate => true, :persistent => true)

      assert options[:mandatory]
      assert options[:immediate]
      assert options[:persistent]
      assert_equal key, options[:key]
      assert_equal "1", options[:headers][:flags]
    end

    test "the publishing options should silently ignore other parameters than the valid publishing keys" do
      options = Message.publishing_options(:redundant => true, :mandatory => true, :bogus => true)
      assert_equal "1", options[:headers][:flags]
      assert options[:mandatory]
      assert_nil options[:bogus]
    end

    test "the publishing options for a redundant message should include the uuid" do
      uuid = 'wadduyouwantfromme'
      Message.expects(:generate_uuid).returns(uuid)
      options = Message.publishing_options(:redundant => true)
      assert_equal uuid, options[:message_id]
    end

    test "the publishing options must only include string values" do
      options = Message.publishing_options(:redundant => true, :mandatory => true, :bogus => true)
      assert options[:headers].all? {|_, param| param.is_a?(String)}
    end

  end

  class KeyManagementTest < Test::Unit::TestCase
    def setup
      @store = DeduplicationStore.new
      @store.flushdb
    end

    test "should be able to extract msg_id from any key" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      @store.keys(message.msg_id).each do |key|
        assert_equal message.msg_id, @store.msg_id(key)
      end
    end

    test "should be able to garbage collect expired keys" do
      Beetle.config.expects(:gc_threshold).returns(0)
      header = header_with_params({:ttl => 0})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert !message.key_exists?
      assert message.key_exists?
      @store.redis.expects(:del).with(*@store.keys(message.msg_id))
      @store.garbage_collect_keys(Time.now.to_i+1)
    end

    test "should not garbage collect not yet expired keys" do
      Beetle.config.expects(:gc_threshold).returns(0)
      header = header_with_params({:ttl => 0})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert !message.key_exists?
      assert message.key_exists?
      @store.redis.expects(:del).never
      @store.garbage_collect_keys(Time.now.to_i-1)
    end

    test "successful processing of a non redundant message should delete all keys from the database" do
      header = header_with_params({})
      header.expects(:ack)
      message = Message.new("somequeue", header, 'foo', :store => @store)

      assert !message.expired?
      assert !message.redundant?

      message.process(lambda {|*args|})

      @store.keys(message.msg_id).each do |key|
        assert !@store.redis.exists(key)
      end
    end

    test "succesful processing of a redundant message twice should delete all keys from the database" do
      header = header_with_params({:redundant => true})
      header.expects(:ack).twice
      message = Message.new("somequeue", header, 'foo', :store => @store)

      assert !message.expired?
      assert message.redundant?

      message.process(lambda {|*args|})
      message.process(lambda {|*args|})

      @store.keys(message.msg_id).each do |key|
        assert !@store.redis.exists(key)
      end
    end

    test "successful processing of a redundant message once should insert all but the delay key and the exception count key into the database" do
      header = header_with_params({:redundant => true})
      header.expects(:ack)
      message = Message.new("somequeue", header, 'foo', :store => @store)

      assert !message.expired?
      assert message.redundant?

      message.process(lambda {|*args|})

      assert @store.exists(message.msg_id, :status)
      assert @store.exists(message.msg_id, :expires)
      assert @store.exists(message.msg_id, :attempts)
      assert @store.exists(message.msg_id, :timeout)
      assert @store.exists(message.msg_id, :ack_count)
      assert !@store.exists(message.msg_id, :delay)
      assert !@store.exists(message.msg_id, :exceptions)
    end
  end

  class AckingTest < Test::Unit::TestCase

    def setup
      @store = DeduplicationStore.new
      @store.flushdb
    end

    test "an expired message should be acked without calling the handler" do
      header = header_with_params(:ttl => -1)
      header.expects(:ack)
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert message.expired?

      processed = :no
      message.process(lambda {|*args| processed = true})
      assert_equal :no, processed
    end

    test "a delayed message should not be acked and the handler should not be called" do
      header = header_with_params()
      header.expects(:ack).never
      message = Message.new("somequeue", header, 'foo', :attempts => 2, :store => @store)
      message.set_delay!
      assert !message.key_exists?
      assert message.delayed?

      processed = :no
      message.process(lambda {|*args| processed = true})
      assert_equal :no, processed
    end

    test "acking a non redundant message should remove the ack_count key" do
      header = header_with_params({})
      header.expects(:ack)
      message = Message.new("somequeue", header, 'foo', :store => @store)

      message.process(lambda {|*args|})
      assert !message.redundant?
      assert !@store.exists(message.msg_id, :ack_count)
    end

    test "a redundant message should be acked after calling the handler" do
      header = header_with_params({:redundant => true})
      message = Message.new("somequeue", header, 'foo', :store => @store)

      message.expects(:ack!)
      assert message.redundant?
      message.process(lambda {|*args|})
    end

    test "acking a redundant message should increment the ack_count key" do
      header = header_with_params({:redundant => true})
      header.expects(:ack)
      message = Message.new("somequeue", header, 'foo', :store => @store)

      assert_equal nil, @store.get(message.msg_id, :ack_count)
      message.process(lambda {|*args|})
      assert message.redundant?
      assert_equal "1", @store.get(message.msg_id, :ack_count)
    end

    test "acking a redundant message twice should remove the ack_count key" do
      header = header_with_params({:redundant => true})
      header.expects(:ack).twice
      message = Message.new("somequeue", header, 'foo', :store => @store)

      message.process(lambda {|*args|})
      message.process(lambda {|*args|})
      assert message.redundant?
      assert !@store.exists(message.msg_id, :ack_count)
    end

  end

  class FreshMessageTest < Test::Unit::TestCase
    def setup
      @store = DeduplicationStore.new
      @store.flushdb
    end

    test "processing a fresh message sucessfully should first run the handler and then ack it" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :attempts => 2, :store => @store)
      assert !message.attempts_limit_reached?

      proc = mock("proc")
      s = sequence("s")
      proc.expects(:call).in_sequence(s)
      header.expects(:ack).in_sequence(s)
      assert_equal RC::OK, message.process(proc)
    end

    test "after processing a redundant fresh message successfully the ack count should be 1 and the status should be completed" do
      header = header_with_params({:redundant => true})
      message = Message.new("somequeue", header, 'foo', :timeout => 10.seconds, :store => @store)
      assert !message.attempts_limit_reached?
      assert message.redundant?

      proc = mock("proc")
      s = sequence("s")
      proc.expects(:call).in_sequence(s)
      message.expects(:completed!).in_sequence(s)
      header.expects(:ack).in_sequence(s)
      assert_equal RC::OK, message.__send__(:process_internal, proc)
      assert_equal "1", @store.get(message.msg_id, :ack_count)
    end

  end

  class SimpleMessageTest < Test::Unit::TestCase
    def setup
      @store = DeduplicationStore.new
      @store.flushdb
      @store.expects(:redis).never
    end

    test "when processing a simple message, ack should precede calling the handler" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :attempts => 1, :store => @store)

      proc = mock("proc")
      s = sequence("s")
      header.expects(:ack).in_sequence(s)
      proc.expects(:call).in_sequence(s)
      assert_equal RC::OK, message.process(proc)
    end

    test "when processing a simple message, RC::AttemptsLimitReached should be returned if the handler crashes" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :attempts => 1, :store => @store)

      proc = mock("proc")
      s = sequence("s")
      header.expects(:ack).in_sequence(s)
      e = Exception.new("ohoh")
      proc.expects(:call).in_sequence(s).raises(e)
      proc.expects(:process_exception).with(e).in_sequence(s)
      proc.expects(:process_failure).with(RC::AttemptsLimitReached).in_sequence(s)
      assert_equal RC::AttemptsLimitReached, message.process(proc)
    end

  end

  class HandlerCrashTest < Test::Unit::TestCase
    def setup
      @store = DeduplicationStore.new
      @store.flushdb
    end

    test "a message should not be acked if the handler crashes and the exception limit has not been reached" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :delay => 42, :timeout => 10.seconds, :exceptions => 1, :store => @store)
      assert !message.attempts_limit_reached?
      assert !message.exceptions_limit_reached?
      assert !message.timed_out?

      proc = lambda {|*args| raise "crash"}
      message.stubs(:now).returns(10)
      message.expects(:completed!).never
      header.expects(:ack).never
      assert_equal RC::HandlerCrash, message.__send__(:process_internal, proc)
      assert !message.completed?
      assert_equal "1", @store.get(message.msg_id, :exceptions)
      assert_equal "0", @store.get(message.msg_id, :timeout)
      assert_equal "52", @store.get(message.msg_id, :delay)
    end

    test "a message should delete the mutex before resetting the timer if attempts and exception limits havn't been reached" do
      Message.stubs(:now).returns(9)
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :delay => 42, :timeout => 10.seconds, :exceptions => 1, :store => @store)
      assert !message.attempts_limit_reached?
      assert !message.exceptions_limit_reached?
      assert !@store.get(message.msg_id, :mutex)
      assert !message.timed_out?

      proc = lambda {|*args| raise "crash"}
      message.expects(:delete_mutex!)
      message.stubs(:now).returns(10)
      message.expects(:completed!).never
      header.expects(:ack).never
      assert_equal RC::HandlerCrash, message.__send__(:process_internal, proc)
    end

    test "a message should be acked if the handler crashes and the exception limit has been reached" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :timeout => 10.seconds, :attempts => 2, :store => @store)
      assert !message.attempts_limit_reached?
      assert !message.exceptions_limit_reached?
      assert !message.timed_out?
      assert !message.simple?

      proc = lambda {|*args| raise "crash"}
      s = sequence("s")
      message.expects(:completed!).never
      header.expects(:ack)
      assert_equal RC::ExceptionsLimitReached, message.__send__(:process_internal, proc)
    end

    test "a message should be acked if the handler crashes and the attempts limit has been reached" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :timeout => 10.seconds, :attempts => 2, :store => @store)
      message.increment_execution_attempts!
      assert !message.attempts_limit_reached?
      assert !message.exceptions_limit_reached?
      assert !message.timed_out?

      proc = lambda {|*args| raise "crash"}
      s = sequence("s")
      message.expects(:completed!).never
      header.expects(:ack)
      assert_equal RC::AttemptsLimitReached, message.__send__(:process_internal, proc)
    end

  end

  class SeenMessageTest < Test::Unit::TestCase
    def setup
      @store = DeduplicationStore.new
      @store.flushdb
    end

    test "a message with an exception set should not be processed at all, but it should be acked" do
      header = {}
      message = Message.new("somequeue", header, 'foo')
      assert message.exception

      proc = mock("proc")
      proc.expects(:call).never
      message.expects(:ack!)
      assert_equal RC::DecodingError, message.__send__(:process_internal, proc)
    end

    test "a completed existing message should be just acked and not run the handler" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :attempts => 2, :store => @store)
      assert !message.key_exists?
      message.completed!
      assert message.completed?

      proc = mock("proc")
      header.expects(:ack)
      proc.expects(:call).never
      assert_equal RC::OK, message.__send__(:process_internal, proc)
    end

    test "an incomplete, delayed existing message should be processed later" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :delay => 10.seconds, :attempts => 2, :store => @store)
      assert !message.key_exists?
      assert !message.completed?
      message.set_delay!
      assert message.delayed?

      proc = mock("proc")
      header.expects(:ack).never
      proc.expects(:call).never
      assert_equal RC::Delayed, message.__send__(:process_internal, proc)
      assert message.delayed?
      assert !message.completed?
    end

    test "an incomplete, undelayed, not yet timed out, existing message should be processed later" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :timeout => 10.seconds, :attempts => 2, :store => @store)
      assert !message.key_exists?
      assert !message.completed?
      assert !message.delayed?
      message.set_timeout!
      assert !message.timed_out?

      proc = mock("proc")
      header.expects(:ack).never
      proc.expects(:call).never
      assert_equal RC::HandlerNotYetTimedOut, message.__send__(:process_internal, proc)
      assert !message.delayed?
      assert !message.completed?
      assert !message.timed_out?
    end

    test "an incomplete, undelayed, not yet timed out, existing message which has reached the handler execution attempts limit should be acked and not run the handler" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :attempts => 2, :store => @store)
      message.increment_execution_attempts!
      assert !message.key_exists?
      assert !message.completed?
      assert !message.delayed?
      message.timed_out!
      assert message.timed_out?

      assert !message.attempts_limit_reached?
      message.attempts_limit.times {message.increment_execution_attempts!}
      assert message.attempts_limit_reached?

      proc = mock("proc")
      header.expects(:ack)
      proc.expects(:call).never
      assert_equal RC::AttemptsLimitReached, message.send(:process_internal, proc)
    end

    test "an incomplete, undelayed, timed out, existing message which has reached the exceptions limit should be acked and not run the handler" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :attempts => 2, :store => @store)
      message.increment_execution_attempts!
      assert !message.key_exists?
      assert !message.completed?
      assert !message.delayed?
      message.timed_out!
      assert message.timed_out?
      assert !message.attempts_limit_reached?
      message.increment_exception_count!
      assert message.exceptions_limit_reached?

      proc = mock("proc")
      header.expects(:ack)
      proc.expects(:call).never
      assert_equal RC::ExceptionsLimitReached, message.send(:process_internal, proc)
    end

    test "an incomplete, undelayed, timed out, existing message should be processed again if the mutex can be aquired" do
      header = header_with_params({:redundant => true})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert !message.key_exists?
      assert !message.completed?
      assert !message.delayed?
      message.timed_out!
      assert message.timed_out?
      assert !message.attempts_limit_reached?
      assert !message.exceptions_limit_reached?

      proc = mock("proc")
      s = sequence("s")
      message.expects(:set_timeout!).in_sequence(s)
      proc.expects(:call).in_sequence(s)
      header.expects(:ack).in_sequence(s)
      assert_equal RC::OK, message.__send__(:process_internal, proc)
      assert message.completed?
    end

    test "an incomplete, undelayed, timed out, existing message should not be processed again if the mutex cannot be aquired" do
      header = header_with_params({:redundant => true})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert !message.key_exists?
      assert !message.completed?
      assert !message.delayed?
      message.timed_out!
      assert message.timed_out?
      assert !message.attempts_limit_reached?
      assert !message.exceptions_limit_reached?
      message.aquire_mutex!
      assert @store.exists(message.msg_id, :mutex)

      proc = mock("proc")
      proc.expects(:call).never
      header.expects(:ack).never
      assert_equal RC::MutexLocked, message.__send__(:process_internal, proc)
      assert !message.completed?
      assert !@store.exists(message.msg_id, :mutex)
    end

  end

  class ProcessingTest < Test::Unit::TestCase
    def setup
      @store = DeduplicationStore.new
      @store.flushdb
    end

    test "processing a message catches internal exceptions risen by process_internal and returns an internal error" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      message.expects(:process_internal).raises(Exception.new("this is expected"))
      handler = Handler.new
      handler.expects(:process_exception).never
      handler.expects(:process_failure).never
      assert_equal RC::InternalError, message.process(1)
    end

    test "processing a message with a crashing processor calls the processors exception handler and returns an internal error" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :exceptions => 1, :store => @store)
      errback = lambda{|*args|}
      exception = Exception.new
      action = lambda{|*args| raise exception}
      handler = Handler.create(action, :errback => errback)
      handler.expects(:process_exception).with(exception).once
      handler.expects(:process_failure).never
      result = message.process(handler)
      assert_equal RC::HandlerCrash, result
      assert result.reject?
      assert !result.failure?
    end

    test "processing a message with a crashing processor calls the processors exception handler and failure handler if the attempts limit has been reached" do
      header = header_with_params({})
      header.expects(:ack)
      message = Message.new("somequeue", header, 'foo', :attempts => 2, :store => @store)
      message.increment_execution_attempts!
      errback = mock("errback")
      failback = mock("failback")
      exception = Exception.new
      action = lambda{|*args| raise exception}
      handler = Handler.create(action, :errback => errback, :failback => failback)
      errback.expects(:call).once
      failback.expects(:call).once
      result = message.process(handler)
      assert_equal RC::AttemptsLimitReached, result
      assert !result.reject?
      assert result.failure?
    end

    test "processing a message with a crashing processor calls the processors exception handler and failure handler if the exceptions limit has been reached" do
      header = header_with_params({})
      header.expects(:ack)
      message = Message.new("somequeue", header, 'foo', :attempts => 2, :store => @store)
      errback = mock("errback")
      failback = mock("failback")
      exception = Exception.new
      action = lambda{|*args| raise exception}
      handler = Handler.create(action, :errback => errback, :failback => failback)
      errback.expects(:call).once
      failback.expects(:call).once
      result = message.process(handler)
      assert_equal RC::ExceptionsLimitReached, result
      assert !result.reject?
      assert result.failure?
    end

  end

  class HandlerTimeoutTest < Test::Unit::TestCase
    def setup
      @store = DeduplicationStore.new
      @store.flushdb
    end

    test "a handler running longer than the specified timeout should be aborted (when given a float timeout number)" do
      header = header_with_params({})
      header.expects(:ack)
      message = Message.new("somequeue", header, 'foo', :timeout => 0.1, :attempts => 2, :store => @store)
      action = lambda{|*args| while true; end}
      handler = Handler.create(action)
      result = message.process(handler)
      assert_equal RC::ExceptionsLimitReached, result
    end

    test "a handler running longer than the specified timeout should be aborted (when using active_support seconds)" do
      header = header_with_params({})
      header.expects(:ack)
      message = Message.new("somequeue", header, 'foo', :timeout => 1.seconds, :attempts => 2, :store => @store)
      action = lambda{|*args| while true; end}
      handler = Handler.create(action)
      result = message.process(handler)
      assert_equal RC::ExceptionsLimitReached, result
    end

  end

  class SettingsTest < Test::Unit::TestCase
    def setup
      @store = DeduplicationStore.new
      @store.flushdb
    end

    test "completed! should store the status 'complete' in the database" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert !message.completed?
      message.completed!
      assert message.completed?
      assert_equal "completed", @store.get(message.msg_id, :status)
    end

    test "set_delay! should store the current time plus the number of delayed seconds in the database" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :delay => 1, :store => @store)
      message.expects(:now).returns(1)
      message.set_delay!
      assert_equal "2", @store.get(message.msg_id, :delay)
      message.expects(:now).returns(2)
      assert !message.delayed?
      message.expects(:now).returns(0)
      assert message.delayed?
    end

    test "set_delay! should use the default delay if the delay hasn't been set on the message instance" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      message.expects(:now).returns(0)
      message.set_delay!
      assert_equal "#{Message::DEFAULT_HANDLER_EXECUTION_ATTEMPTS_DELAY}", @store.get(message.msg_id, :delay)
      message.expects(:now).returns(message.delay)
      assert !message.delayed?
      message.expects(:now).returns(0)
      assert message.delayed?
    end

    test "set_timeout! should store the current time plus the number of timeout seconds in the database" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :timeout => 1, :store => @store)
      message.expects(:now).returns(1)
      message.set_timeout!
      assert_equal "2", @store.get(message.msg_id, :timeout)
      message.expects(:now).returns(2)
      assert !message.timed_out?
      message.expects(:now).returns(3)
      assert message.timed_out?
    end

    test "set_timeout! should use the default timeout if the timeout hasn't been set on the message instance" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      message.expects(:now).returns(0)
      message.set_timeout!
      assert_equal "#{Message::DEFAULT_HANDLER_TIMEOUT}", @store.get(message.msg_id, :timeout)
      message.expects(:now).returns(message.timeout)
      assert !message.timed_out?
      message.expects(:now).returns(Message::DEFAULT_HANDLER_TIMEOUT+1)
      assert message.timed_out?
    end

    test "incrementing execution attempts should increment by 1" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert_equal 1, message.increment_execution_attempts!
      assert_equal 2, message.increment_execution_attempts!
      assert_equal 3, message.increment_execution_attempts!
    end

    test "accessing execution attempts should return the number of execution attempts made so far" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert_equal 0, message.attempts
      message.increment_execution_attempts!
      assert_equal 1, message.attempts
      message.increment_execution_attempts!
      assert_equal 2, message.attempts
      message.increment_execution_attempts!
      assert_equal 3, message.attempts
    end

    test "accessing execution attempts should return 0 if none were made" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert_equal 0, message.attempts
    end


    test "attempts limit should be set exception limit + 1 iff the configured attempts limit is equal to or smaller than the exceptions limit" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :exceptions => 1, :store => @store)
      assert_equal 2, message.attempts_limit
      assert_equal 1, message.exceptions_limit
      message = Message.new("somequeue", header, 'foo', :exceptions => 2, :store => @store)
      assert_equal 3, message.attempts_limit
      assert_equal 2, message.exceptions_limit
      message = Message.new("somequeue", header, 'foo', :attempts => 5, :exceptions => 2, :store => @store)
      assert_equal 5, message.attempts_limit
      assert_equal 2, message.exceptions_limit
    end

    test "attempts limit should be reached after incrementing the attempt limit counter 'attempts limit' times" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :attempts =>2, :store => @store)
      assert !message.attempts_limit_reached?
      message.increment_execution_attempts!
      assert !message.attempts_limit_reached?
      message.increment_execution_attempts!
      assert message.attempts_limit_reached?
      message.increment_execution_attempts!
      assert message.attempts_limit_reached?
    end

    test "incrementing exception counts should increment by 1" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert_equal 1, message.increment_exception_count!
      assert_equal 2, message.increment_exception_count!
      assert_equal 3, message.increment_exception_count!
    end

    test "default exceptions limit should be reached after incrementing the attempt limit counter 1 time" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert !message.exceptions_limit_reached?
      message.increment_exception_count!
      assert message.exceptions_limit_reached?
    end

    test "exceptions limit should be reached after incrementing the attempt limit counter 'exceptions limit + 1' times" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :exceptions => 1, :store => @store)
      assert !message.exceptions_limit_reached?
      message.increment_exception_count!
      assert !message.exceptions_limit_reached?
      message.increment_exception_count!
      assert message.exceptions_limit_reached?
      message.increment_exception_count!
      assert message.exceptions_limit_reached?
    end

    test "failure to aquire a mutex should delete it from the database" do
      header = header_with_params({})
      message = Message.new("somequeue", header, 'foo', :store => @store)
      assert message.aquire_mutex!
      assert !message.aquire_mutex!
      assert !@store.exists(message.msg_id, :mutex)
    end
  end

end

