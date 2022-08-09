module ActiveRecord
  module Bogacs
    module ThreadSafe

      require 'concurrent/map.rb'
      Map = ::Concurrent::Map

      autoload :Synchronized, 'active_record/bogacs/thread_safe/synchronized'

    end
  end
end
