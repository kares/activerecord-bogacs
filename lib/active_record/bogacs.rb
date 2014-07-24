require 'active_record/bogacs/version'

require 'active_record'
require 'active_record/connection_adapters/abstract/connection_pool'

module ActiveRecord
  module Bogacs
    autoload :FalsePool, 'active_record/bogacs/false_pool'
    autoload :ShareablePool, 'active_record/bogacs/shareable_pool'
  end
  autoload :SharedConnection, 'active_record/shared_connection'
end

# NOTE: needs explicit configuration - before connection gets established e.g.
#
#   klass = ActiveRecord::Bogacs::FalsePool
#   ActiveRecord::ConnectionAdapters::ConnectionHandler.connection_pool_class = klass
#
module ActiveRecord
  module ConnectionAdapters
    # @private there's no other way to change the pool class to use but to patch :(
    ConnectionHandler.class_eval do

      @@connection_pool_class = ConnectionAdapters::ConnectionPool

      def connection_pool_class; @@connection_pool_class end
      def self.connection_pool_class=(klass); @@connection_pool_class = klass end

      def establish_connection(owner, spec)
        @class_to_pool.clear
        owner_to_pool[owner.name] = connection_pool_class.new(spec)
      end

    end
  end
end