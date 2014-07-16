module ActiveRecord
  module SharedConnection

    def with_shared_connection(&block)
      ActiveRecord::SharedConnection.with_shared_connection(self.class, &block)
    end

    # NOTE: shareable pool loaded and setup to be used (from an initializer) :
    if ActiveRecord::Base.connection_pool.respond_to?(:with_shared_connection)

      def self.with_shared_connection(model = ActiveRecord::Base, &block)
        model.connection_pool.with_shared_connection(&block)
      end

    else

      def self.with_shared_connection(model = ActiveRecord::Base, &block)
        model.connection_pool.with_connection(&block) # default pool is used
      end

    end

  end
end