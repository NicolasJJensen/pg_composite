module PgComposite
  class Value
    class_attribute :members, default: {}.freeze
    class_attribute :sql_type

    def self.member(name, type: :float, column: name, default: nil)
      self.members = members.merge(name.to_s => { type: ActiveModel::Type.lookup(type), column: column.to_s, default: default }).freeze
      define_method(name) { @values.fetch(name.to_s) }
      define_method("#{name}=") { |value| @values[name.to_s] = cast_member(name.to_s, value) }
    end

    def initialize(input = {})
      input = input.to_h if input.is_a?(self.class)
      input = PG::TextDecoder::Record.new.decode(input) if input.is_a?(String)
      input = self.class.members.keys.zip(input).to_h if input.is_a?(Array)
      raise ArgumentError, "Expected a hash, tuple, or composite value" unless input.is_a?(Hash)
      input = input.transform_keys(&:to_s)
      unknown = input.keys - self.class.members.keys
      raise ArgumentError, "Unknown composite members: #{unknown.join(', ')}" unless unknown.empty?
      @values = self.class.members.to_h do |name, definition|
        [name, cast_member(name, input.fetch(name, definition[:default]))]
      end
    end

    def to_h = @values.transform_keys(&:to_sym)
    def serialize = PG::TextEncoder::Record.new.encode(@values.values)
    def to_s = serialize
    def ==(other) = other.instance_of?(self.class) && other.to_h == to_h
    alias eql? ==
    def hash = [self.class, to_h].hash

    private

    def cast_member(name, value)
      type = self.class.members.fetch(name)[:type]
      return nil if value.nil? || value == ""
      # Reject malformed numeric form input rather than silently turning it into zero.
      Float(value) if type.type == :float
      Integer(value, 10) if type.type == :integer && value.is_a?(String)
      type.cast(value)
    end
  end
end
