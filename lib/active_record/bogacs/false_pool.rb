module ActiveRecord
  module Bogacs
    class FalsePool

      include ThreadSafe::Util::CheapLockable
      alias_method :synchronize, :cheap_synchronize

      attr_accessor :automatic_reconnect

      attr_reader :size, :spec

      def initialize(spec)
        @connected = nil

        @spec = spec
        @size = nil
        #@automatic_reconnect = true

        @reserved_connections = ThreadSafe::Cache.new #:initial_capacity => @size
      end

      # @private replacement for attr_reader :connections
      def connections; @reserved_connections.values end

      # @private attr_reader :reaper
      def reaper; end

      # @private
      def checkout_timeout; end

      # Retrieve the connection associated with the current thread, or call
      # #checkout to obtain one if necessary.
      #
      # #connection can be called any number of times; the connection is
      # held in a hash keyed by the thread id.
      def connection
        @reserved_connections[current_connection_id] ||= checkout
      end

      # Is there an open connection that is being used for the current thread?
      def active_connection?
        conn = @reserved_connections[current_connection_id]
        conn ? conn.in_use? : false
      end

      # Signal that the thread is finished with the current connection.
      # #release_connection releases the connection-thread association
      # and returns the connection to the pool.
      def release_connection(with_id = current_connection_id)
        conn = @reserved_connections.delete(with_id)
        checkin conn if conn
      end

      # If a connection already exists yield it to the block. If no connection
      # exists checkout a connection, yield it to the block, and checkin the
      # connection when finished.
      def with_connection
        connection_id = current_connection_id
        fresh_connection = true unless active_connection?
        yield connection
      ensure
        release_connection(connection_id) if fresh_connection
      end

      # Returns true if a connection has already been opened.
      def connected?; @connected end

      # Disconnects all connections in the pool, and clears the pool.
      def disconnect!
        synchronize do
          @connected = false

          connections = @reserved_connections.values
          @reserved_connections.clear

          connections.each do |conn|
            checkin conn
            conn.disconnect!
          end

          #@reserved_connections.clear
          #@connections.each do |conn|
            #checkin conn
            #conn.disconnect!
          #end
          #@connections = []
          #@available.clear
        end
      end

      # Clears the cache which maps classes.
      def clear_reloadable_connections!
        synchronize do
          @connected = false

          connections = @reserved_connections.values
          @reserved_connections.clear

          connections.each do |conn|
            checkin conn
            conn.disconnect! if conn.requires_reloading?
          end

          #@reserved_connections.clear
          #@connections.each do |conn|
            #checkin conn
            #conn.disconnect! if conn.requires_reloading?
          #end
          #@connections.delete_if do |conn|
            #conn.requires_reloading?
          #end
          #@available.clear
          #@connections.each do |conn|
            #@available.add conn
          #end
        end
      end

      # Check-out a database connection from the pool, indicating that you want
      # to use it. You should call #checkin when you no longer need this.
      #
      # This is done by either returning and leasing existing connection, or by
      # creating a new connection and leasing it.
      #
      # If all connections are leased and the pool is at capacity (meaning the
      # number of currently leased connections is greater than or equal to the
      # size limit set), an ActiveRecord::ConnectionTimeoutError exception will be raised.
      #
      # Returns: an AbstractAdapter object.
      #
      # Raises:
      # - ConnectionTimeoutError: no connection can be obtained from the pool.
      def checkout
        #synchronize do
          conn = checkout_new_connection # acquire_connection
          conn.lease
          conn.run_callbacks(:checkout) { conn.verify! } # checkout_and_verify(conn)
          conn
        #end
      end

      # Check-in a database connection back into the pool, indicating that you
      # no longer need this connection.
      #
      # +conn+: an AbstractAdapter object, which was obtained by earlier by
      # calling +checkout+ on this pool.
      def checkin(conn)
        release conn
        #synchronize do
          conn.run_callbacks(:checkin) { conn.expire }
          #release conn
          #@available.add conn
        #end
      end

      # Remove a connection from the connection pool.  The connection will
      # remain open and active but will no longer be managed by this pool.
      def remove(conn)
        #synchronize do
          #@connections.delete conn
          #@available.delete conn

          release conn

          #@available.add checkout_new_connection if @available.any_waiting?
        #end
      end

      # @private
      def reap
        # we do not really manage the connection pool - nothing to do ...
      end

      private

      # Acquire a connection by one of 1) immediately removing one
      # from the queue of available connections, 2) creating a new
      # connection if the pool is not at capacity, 3) waiting on the
      # queue for a connection to become available.
      #
      # Raises:
      # - ConnectionTimeoutError if a connection could not be acquired
      def acquire_connection
        # underlying pool will poll and block if "empty" (all checked-out)
        #if conn = @available.poll
          #conn
        #elsif @connections.size < @size
          #checkout_new_connection
        #else
          #reap
          #@available.poll(@checkout_timeout)
        #end
        checkout_new_connection
      end

      def release(conn, owner = nil)
        thread_id = owner.object_id unless owner.nil?

        thread_id ||=
          if @reserved_connections[conn_id = current_connection_id] == conn
            conn_id
          else
            connections = @reserved_connections
            connections.keys.find { |k| connections[k] == conn }
          end

        @reserved_connections.delete thread_id if thread_id
      end

      def new_connection
        Base.send(spec.adapter_method, spec.config)
      end

      def current_connection_id
        Base.connection_id ||= Thread.current.object_id # TODO
      end

      def checkout_new_connection
        # NOTE: automatic reconnect seems to make no sense for us!
        #raise ConnectionNotEstablished unless @automatic_reconnect

        conn = new_connection
        conn.pool = self
        synchronize { @connected = true } if @connected != true
        conn
      end

      #def checkout_and_verify(conn)
      #  conn.run_callbacks(:checkout) { conn.verify! }
      #  conn
      #end

    end
  end
end