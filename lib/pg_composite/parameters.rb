module PgComposite
  module Parameters
    extend ActiveSupport::Concern

    class_methods do
      def cast_parameter(path, type:, permit:, **callback_options)
        path = Array(path).map(&:to_s).freeze
        raise ArgumentError, "Parameter path cannot be empty" if path.empty?
        before_action(**callback_options) do
          parent = path[0...-1].reduce(params) do |container, key|
            break nil unless container.is_a?(ActionController::Parameters)
            container[key]
          end
          next unless parent.is_a?(ActionController::Parameters) && parent.key?(path.last)
          raw = parent[path.last]
          unless raw.is_a?(ActionController::Parameters)
            raise ActionController::BadRequest, "Expected an object for #{path.join('.')}"
          end
          begin
            typed = type.cast(raw.permit(*permit).to_h)
          rescue ArgumentError, TypeError => error
            raise ActionController::BadRequest, "Invalid #{path.join('.')}: #{error.message}"
          end
          parent[path.last] = typed
          (@composite_parameters ||= {})[path] = typed
        end
      end
    end

    # Only merge values that this concern has already filtered and cast.
    def typed_parameters(root = nil, permit: [])
      prefix = Array(root).map(&:to_s)
      source = prefix.reduce(params) { |container, key| container.require(key) }
      attributes = source.permit(*permit).to_h
      (@composite_parameters || {}).each do |path, value|
        next unless path[0...-1] == prefix
        attributes[path.last] = value
      end
      attributes
    end
  end
end
