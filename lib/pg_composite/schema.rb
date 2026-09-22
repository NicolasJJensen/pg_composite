module PgComposite
  class SchemaMismatch < StandardError; end

  class Schema
    def initialize(type, connection)
      @type = type
      @connection = connection
    end

    def validate!(column: nil, table: nil)
      unless @connection.adapter_name == "PostgreSQL"
        raise UnsupportedAdapter, "pg_composite requires the PostgreSQL adapter (connection is #{@connection.adapter_name})"
      end

      sql = <<~SQL
        SELECT t.oid, t.typtype, a.attname, #{column_oid_sql(column, table)} AS column_oid
        FROM pg_catalog.pg_type t
        LEFT JOIN pg_catalog.pg_attribute a
          ON a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped
        WHERE t.oid = pg_catalog.to_regtype(#{@connection.quote(quoted_type_name)})
        ORDER BY a.attnum
      SQL
      rows = @connection.uncached do
        @connection.select_all(sql, "PgComposite schema validation").to_a
      end
      mismatch!("type does not exist") if rows.empty?
      mismatch!("type is not composite") unless rows.first.fetch("typtype") == "c"

      declared = @type.members.values.map { |member| member.fetch(:column) }
      database = rows.filter_map { |row| row["attname"] }
      if declared != database
        mismatch!("Ruby declares #{declared.inspect}, PostgreSQL declares #{database.inspect}")
      end
      if column && rows.first["column_oid"].to_i != rows.first.fetch("oid").to_i
        mismatch!("column #{column.name.inspect} uses PostgreSQL type OID #{rows.first["column_oid"].inspect}, expected #{rows.first.fetch("oid")}")
      end
      true
    end

    private

    def column_oid_sql(column, table)
      return "NULL" unless column

      <<~SQL.squish
        (SELECT atttypid FROM pg_catalog.pg_attribute
         WHERE attrelid = pg_catalog.to_regclass(#{@connection.quote(@connection.quote_table_name(table))})
           AND attname = #{@connection.quote(column.name)} AND NOT attisdropped)
      SQL
    end

    def quoted_type_name
      @type.sql_type.split(".").map { |part| @connection.quote_column_name(part) }.join(".")
    end

    def mismatch!(message)
      raise SchemaMismatch, "#{@type.value_class} (#{@type.sql_type}): #{message}"
    end
  end
end
