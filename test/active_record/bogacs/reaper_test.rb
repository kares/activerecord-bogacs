require File.expand_path('../../test_helper', File.dirname(__FILE__))
require 'stringio'

module ActiveRecord
  module Bogacs
    class ReaperTest < Test::Unit::TestCase

      def self.startup
        super; require 'active_record/bogacs/reaper'
        Reaper.const_set :Thread, AbortiveThread
      end

      def config; AR_CONFIG end

      def setup
        super
        ActiveRecord::Base.establish_connection config.merge :reaping_frequency => 0.25
        @pool = DefaultPool.new ActiveRecord::Base.connection_pool.spec
      end

      def test_null_reaper
        ActiveRecord::Base.establish_connection config.merge :reaping_frequency => false
        pool = DefaultPool.new ActiveRecord::Base.connection_pool.spec

        assert ! pool.reaper?
        sleep 0.1
        assert ! pool.reaping?
      end

      def test_reaper?
        assert @pool.reaper?
        sleep 0.1
        assert @pool.reaping?
      end

      def test_reap_error_restart
        logger = Logger.new str = StringIO.new
        @pool.reaper.instance_variable_set :@logger, logger
        def @pool.reap; raise RuntimeError, 'test_reap_error' end

        assert @pool.reaper?
        sleep 0.3
        assert_true @pool.reaping?
        assert_match /WARN.*reaping failed:.* test_reap_error.* restarting after/, str.string
      end

      def test_reap_error_stop
        logger = Logger.new str = StringIO.new
        @pool.reaper.instance_variable_set :@logger, logger
        @pool.reaper.retry_error = false
        def @pool.reap; raise 'test_reap_error2' end

        assert @pool.reaper?
        sleep 0.3
        assert_false @pool.reaping?
        assert_match /WARN.*reaping failed:.* test_reap_error2.* stopping/, str.string
      end

      private

      class AbortiveThread < Thread

        def self.new(*args, &block)
          super.tap { |thread| thread.abort_on_exception = true }
        end

      end

    end
  end
end