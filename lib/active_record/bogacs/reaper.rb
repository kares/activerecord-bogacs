require 'thread'

module ActiveRecord
  module Bogacs

    # Every +frequency+ seconds, the reaper will call +reap+ on +pool+.
    # A reaper instantiated with a nil frequency will never reap the
    # connection pool.
    #
    # Configure the frequency by setting `:reaping_frequency` in your
    # database yaml file.
    class Reaper

      attr_reader :pool, :frequency
      attr_accessor :retry_error

      # Reaper.new(self, spec.config[:reaping_frequency]).run
      # @private
      def initialize(pool, frequency)
        @pool = pool;
        if frequency
          frequency = frequency.to_f
          @frequency = frequency > 0.0 ? frequency : false
        else
          @frequency = nil
        end
        @retry_error = 1.5; @running = nil
      end

      def run
        return unless frequency
        @running = true; start
      end

      def start(delay = nil)
        Thread.new { exec(delay) }
      end

      def running?; @running end

      private

      def exec(delay = nil)
        sleep delay if delay
        while true
          begin
            sleep frequency
            pool.reap
          rescue => e
            log = logger
            if retry_delay = @retry_error
              log && log.warn("[reaper] reaping failed: #{e.inspect} restarting after #{retry_delay}s")
              start retry_delay
            else
              log && log.warn("[reaper] reaping failed: #{e.inspect} stopping reaper")
              @running = false
            end
            break
          end
        end
      end

      def set_thread_name(name)
        if ( thread = Thread.current ).respond_to?(:name)
          thread.name = name; return
        end
        if defined? JRUBY_VERSION
          thread = JRuby.reference(thread).getNativeThread
          thread.setName("#{name} #{thread.getName}")
        else
          thread[:name] = name
        end
      end

      def logger
        @logger ||= ( pool.respond_to?(:logger) ? pool.logger : nil ) rescue nil
      end

    end

  end
end