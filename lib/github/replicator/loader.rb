module GitHub
  module Replicator
    # Load replicants in a streaming fashion.
    #
    # The Loader reads [type, id, attributes] replicant tuples and creates
    # objects in the current environment.
    #
    # Objects are expected to arrive in order such that a record referenced via
    # foreign key always precedes the referencing record. The Loader maintains a
    # mapping of primary keys from the dump system to the current environment.
    # This mapping is used to properly establish new foreign key values on all
    # records inserted.
    class Loader
      attr_reader :stats

      def initialize
        fail "not ready for production" if RAILS_ENV == 'production'
        @keymap = {}
        @warned = {}
        @foreign_key_map = {}
        @filters = []
        @stats = Hash.new { |hash, k| hash[k] = 0 }

        if block_given?
          yield self
          complete
        end
      end

      # Register a load filter to be called for each loaded object with the
      # type, id, attributes, object structure. Filters are executed in the
      # reverse order of which they were registered. Filters registered later
      # modify the view of filters registered earlier.
      #
      # p - An optional Proc object. Must respond to call.
      # block - An optional block.
      #
      # Returns nothing.
      def filter(p=nil, &block)
        @filters.unshift p if p
        @filters.unshift block if block
      end

      # Sugar for creating a filter with an object instance. Instances of the
      # class must respond to call(type, id, attrs, object).
      #
      # klass - The class to create. Must respond to new.
      # args  - Arguments to pass to klass#new in addition to self.
      #
      # Returns the object created.
      def use(klass, *args, &block)
        instance = klass.new(self, *args, &block)
        filter instance
        instance
      end

      # Notify all filters that processing is complete.
      def complete
        @filters.each { |f| f.complete if f.respond_to?(:complete) }
      end

      # Register a filter to write status information to the given stream. By
      # default, a single line is used to report object counts while the dump is
      # in progress; dump counts for each class are written when complete. The
      # verbose and quiet options can be used to increase or decrease
      # verbository.
      #
      # out - An IO object to write to, like stderr.
      # verbose - Whether verbose output should be enabled.
      # quiet - Whether quiet output should be enabled.
      #
      # Returns the Replicator::Status object.
      def log_to(out=$stderr, verbose=false, quiet=false)
        use Replicator::Status, 'load', out, verbose, quiet
      end

      # Feed a single replicant tuple into the loader.
      #
      # type  - The class to create. Must respond to load_replicant.
      # id    - The remote system's id for this object.
      # attrs - Hash of primitively typed objects.
      #
      # Returns the need object resulting from the load operation.
      def feed(type, id, attrs)
        object = load(type, id, attrs)
        @stats[type] += 1
        @filters.each { |filter| filter.call(type, id, attrs, object) }
        object
      end

      # Read multiple [type, id, attrs] replicant tuples from io and call the
      # feed method to load and filter the object.
      def read(io)
        begin
          while object = Marshal.load(io)
            type, id, attrs = object
            feed type, id, attrs
          end
        rescue EOFError
        end
      end

      # Load an individual replicant into the underlying datastore.
      #
      # type  - Model class name as a String.
      # id    - Primary key id of the record on the dump system. This must be
      #         translated to the local system and stored in the keymap.
      # attrs - Hash of attributes to set on the new record.
      #
      # Returns the new object instance.
      def load(type, id, attributes)
        model_class = type.constantize
        translate_ids attributes
        begin
          new_id, instance = model_class.load_replicant(type, id, attributes)
        rescue => boom
          warn "error: loading #{type} #{id} #{boom.class} #{boom}"
        end
        register_id instance, type, id, new_id
        instance
      end

      # Translate remote system id references in the attributes hash to their
      # local system id values. The attributes hash may include special id
      # values like this:
      #     { 'title'         => 'hello there',
      #       'repository_id' => [:id, 'Repository:1234'],
      #       'label_ids'     => [:ids, 'Label', [333, 444, 555, 666, ...]]
      #       ... }
      # These values are translated to local system ids. All object
      # references must be loaded prior to the referencing object.
      def translate_ids(attributes)
        attributes.each do |key, value|
          if value.is_a?(Array) && value.size == 2 && value[0] == :id
            remote_id = value[1]
            if local_id = @keymap[remote_id]
              attributes[key] = local_id
            else
              warn "error: #{remote_id} missing from keymap"
            end
          elsif value.is_a?(Array) && value.size == 3 && value[0] == :ids
            _, type, ids = value
            attributes[key] =
              ids.map do |id|
                if local_id = @keymap["#{type}:#{id}"]
                  local_id
                else
                  warn "error: #{type}:#{id} missing from keymap"
                  nil
                end
              end
          end
        end
      end

      # Register an id in the keymap. Every object loaded must be stored here so
      # that key references can be resolved.
      def register_id(object, type, remote_id, local_id)
        @keymap["#{type}:#{remote_id}"] = local_id
        c = object.class
        while c != Object && c != ActiveRecord::Base
          @keymap["#{c.name}:#{remote_id}"] = local_id
          c = c.superclass
        end
      end
    end
  end
end
