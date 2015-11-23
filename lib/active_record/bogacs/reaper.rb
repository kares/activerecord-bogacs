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

      # Reaper.new(self, spec.config[:reaping_frequency]).run
      # @private
      def initialize(pool, frequency)
        @pool = pool; @frequency = frequency
      end

      def run
        return unless frequency

        Thread.new(frequency, pool) do |t, pool|
          while true
            sleep t
            pool.reap
          end
        end
      end

    end

  end
end