require 'pg_composite'

RSpec.describe PgComposite::Type, '#validate_schema!' do
  before(:all) do
    @database = Object.const_set(:SchemaDatabase, Class.new(ActiveRecord::Base))
    @database.abstract_class = true
    @database.establish_connection(ENV.fetch('TEST_DATABASE_URL', 'postgresql:///postgres'))
    @connection = @database.connection
    @schema = "composite_schema_#{Process.pid}_#{object_id}"
    @connection.execute("CREATE SCHEMA #{@connection.quote_column_name(@schema)}")
    create_type('valid_color', 'lightness float8, color float8, hue float8, alpha float8')
    create_type('reordered_color', 'lightness float8, hue float8, color float8, alpha float8')
    create_type('extra_color', 'lightness float8, color float8, hue float8, alpha float8, note text')
    create_type('missing_color', 'lightness float8, color float8, hue float8')
    create_type('dropped_color', 'lightness float8, obsolete text, hue float8')
    @connection.execute(<<~SQL)
      ALTER TYPE #{qualified_type('dropped_color')} DROP ATTRIBUTE obsolete
    SQL
    @connection.execute(<<~SQL)
      CREATE SCHEMA #{@connection.quote_column_name(@upper_schema = "CompositeUpper#{Process.pid}#{object_id}")}
    SQL
    @connection.execute(<<~SQL)
      CREATE TYPE #{@connection.quote_column_name(@upper_schema)}."ColorType" AS ("Lightness" float8, "Hue" float8)
    SQL
  end

  after(:all) do
    if @connection
      @connection.execute("DROP SCHEMA #{@connection.quote_column_name(@schema)} CASCADE")
      @connection.execute("DROP SCHEMA #{@connection.quote_column_name(@upper_schema)} CASCADE")
      @database.connection_pool.disconnect!
    end
    Object.send(:remove_const, :SchemaDatabase) if Object.const_defined?(:SchemaDatabase, false)
  end

  def create_type(name, attributes)
    @connection.execute("CREATE TYPE #{qualified_type(name)} AS (#{attributes})")
  end

  def qualified_name(name)
    [@schema, name].map { |part| @connection.quote_column_name(part) }.join('.')
  end

  alias qualified_type qualified_name

  def type_name(name)
    "#{@schema}.#{name}"
  end

  def type_for(sql_type, *members)
    value_class = Class.new(PgComposite::Value) do
      self.sql_type = sql_type
      members.each do |member_definition|
        name, column = member_definition.is_a?(Hash) ? member_definition.first : [member_definition, member_definition]
        member(name, column: column)
      end
    end
    PgComposite::Type.new(value_class: value_class, sql_type: sql_type)
  end

  it 'accepts a composite type with matching members' do
    type = type_for(type_name('valid_color'), :lightness, { chroma: :color }, :hue, :alpha)
    expect(type.validate_schema!(connection: @connection)).to be(true)
  end

  it 'rejects reordered members and missing or extra members' do
    reordered = type_for(type_name('reordered_color'), :lightness, { chroma: :color }, :hue, :alpha)
    extra = type_for(type_name('extra_color'), :lightness, { chroma: :color }, :hue, :alpha)
    missing = type_for(type_name('missing_color'), :lightness, { chroma: :color }, :hue, :alpha)

    expect { reordered.validate_schema!(connection: @connection) }
      .to raise_error(PgComposite::SchemaMismatch, /Ruby declares.*PostgreSQL declares/)
    expect { extra.validate_schema!(connection: @connection) }
      .to raise_error(PgComposite::SchemaMismatch, /Ruby declares.*PostgreSQL declares/)
    expect { missing.validate_schema!(connection: @connection) }
      .to raise_error(PgComposite::SchemaMismatch, /Ruby declares.*PostgreSQL declares/)
  end

  it 'uses a member column alias when comparing the declared member name' do
    type = type_for(type_name('valid_color'), :lightness, { chroma: :color }, :hue, :alpha)

    expect(type.validate_schema!(connection: @connection)).to be(true)
  end

  it 'rejects a missing type and a non-composite type' do
    missing = type_for(type_name('does_not_exist'), :lightness)
    scalar = type_for('text', :lightness)

    expect { missing.validate_schema!(connection: @connection) }
      .to raise_error(PgComposite::SchemaMismatch, /type does not exist/)
    expect { scalar.validate_schema!(connection: @connection) }
      .to raise_error(PgComposite::SchemaMismatch, /type is not composite/)
  end

  it 'raises on an explicit check even when automatic validation is disabled' do
    previous = PgComposite.configuration.schema_validation
    PgComposite.configure { |config| config.schema_validation = :none }
    type = type_for(type_name('valid_color'), :hue)
    expect { type.validate_schema!(connection: @connection) }.to raise_error(PgComposite::SchemaMismatch)
  ensure
    PgComposite.configuration.schema_validation = previous
  end

  it 'quotes schema-qualified uppercase identifiers' do
    type = type_for("#{@upper_schema}.ColorType", { lightness: 'Lightness' }, { hue: 'Hue' })
    expect(type.validate_schema!(connection: @connection)).to be(true)
  end

  it 'ignores dropped PostgreSQL attributes' do
    type = type_for(type_name('dropped_color'), :lightness, :hue)

    expect(type.validate_schema!(connection: @connection)).to be(true)
  end
end

RSpec.describe PgComposite::Configuration do
  before do
    @previous_configuration = PgComposite.instance_variable_get(:@configuration)
    PgComposite.instance_variable_set(:@configuration, described_class.new)
  end

  after do
    PgComposite.instance_variable_set(:@configuration, @previous_configuration)
  end

  it 'defaults to error in standalone use' do
    hide_const('Rails') if defined?(Rails)

    expect(PgComposite.configuration.schema_validation).to eq(:error)
  end

  it 'defaults to error in Rails development and test' do
    stub_const('Rails', Module.new)
    Rails.define_singleton_method(:env) { 'development' }
    expect(PgComposite.configuration.schema_validation).to eq(:error)

    PgComposite.instance_variable_set(:@configuration, described_class.new)
    Rails.define_singleton_method(:env) { 'test' }
    expect(PgComposite.configuration.schema_validation).to eq(:error)
  end

  it 'defaults to none in other Rails environments' do
    stub_const('Rails', Module.new)
    Rails.define_singleton_method(:env) { 'production' }

    expect(PgComposite.configuration.schema_validation).to eq(:none)
  end

  it 'rejects invalid validation modes' do
    expect { PgComposite.configuration.schema_validation = :invalid }
      .to raise_error(ArgumentError, /schema_validation must be :error, :warn, or :none/)
  end
end
