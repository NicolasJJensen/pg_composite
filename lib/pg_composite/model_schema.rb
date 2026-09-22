module PgComposite
  module ModelSchema
    def _default_attributes
      super.tap do |attributes|
        # Rails precomputes defaults before all attribute overrides are installed.
        if schema_loaded? && PgComposite.configuration.schema_validation != :none
          types = attributes.each_value.to_h { |attribute| [attribute.name, attribute.type] }
          validate_composite_attributes(types)
        end
      end
    end

    def attribute_types
      super.tap { |types| validate_composite_attributes(types) }
    end

    protected

    def reload_schema_from_cache(*args)
      @pg_composite_schema_checks = nil
      super
    end

    private

    def validate_composite_attributes(types)
      mode = PgComposite.configuration.schema_validation
      return if mode == :none

      composites = types.select { |name, type| type.is_a?(Type) && columns_hash.key?(name) }
      return if composites.empty?

      connection_pool.with_connection do |connection|
        next unless connection.adapter_name == "PostgreSQL"

        signature = [columns_hash, connection.raw_connection, connection.schema_search_path, mode,
                     composites.map { |name, type| [name, type.sql_type, type.value_class, type.members] }]
        checks = @pg_composite_schema_checks ||= {}
        next if checks[connection] == signature

        composites.each do |name, type|
          begin
            Schema.new(type, connection).validate!(column: columns_hash.fetch(name), table: table_name)
          rescue SchemaMismatch => error
            raise if mode == :error
            logger ? logger.warn(error.message) : Kernel.warn(error.message)
          end
        end
        checks[connection] = signature
      end
    end
  end
end
