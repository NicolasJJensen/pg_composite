module PgComposite
  class Type < ActiveModel::Type::Value
    include ActiveModel::Type::Helpers::Mutable
    class_attribute :subtype
    attr_reader :value_class, :sql_type

    def initialize(value_class: self.class.subtype, sql_type: nil)
      @value_class = value_class
      raise ArgumentError, "A composite value class is required" unless value_class
      @sql_type = sql_type || value_class.sql_type
      unless @sql_type&.match?(/\A[a-zA-Z_][\w]*(?:\.[a-zA-Z_][\w]*)?\z/)
        raise ArgumentError, "A simple or schema-qualified PostgreSQL type name is required"
      end
      super()
    end

    def type = :composite
    def cast(value)
      return nil if value.nil?
      return value if value.is_a?(value_class)
      value_class.new(value)
    end
    def serialize(value) = cast(value)&.serialize
    def deserialize(value) = cast(value)
    def changed_in_place?(raw_old_value, new_value) = deserialize(raw_old_value) != cast(new_value)
    def as_json(value) = cast(value)&.to_h&.to_json
    def members = value_class.members
  end
end
