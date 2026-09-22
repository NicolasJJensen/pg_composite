require 'pg_composite'
require 'stringio'

RSpec.describe 'Automatic composite schema validation' do
  before(:all) do
    Object.const_set(:SchemaValidationBase, Class.new(ActiveRecord::Base) { self.abstract_class = true })
    SchemaValidationBase.establish_connection(ENV.fetch('TEST_DATABASE_URL', 'postgresql:///postgres'))
    @connection = SchemaValidationBase.connection
    @connection.execute('CREATE TEMP TABLE validation_namespace (id integer)')
    @connection.execute('CREATE TYPE pg_temp.validation_dimensions AS (width float8, height float8)')
    @connection.execute('CREATE TYPE pg_temp.other_dimensions AS (width float8, height float8)')
    @connection.execute('CREATE TEMP TABLE validation_items (id bigserial PRIMARY KEY, dimensions pg_temp.validation_dimensions, other pg_temp.other_dimensions, name text)')
    @value_class = Class.new(PgComposite::Value) do
      self.sql_type = 'pg_temp.validation_dimensions'
      member :width
      member :height
    end
  end

  after(:all) do
    SchemaValidationBase.connection_pool.disconnect!
    Object.send(:remove_const, :SchemaValidationBase)
  end

  around do |example|
    previous = PgComposite.configuration.schema_validation
    PgComposite.configuration.schema_validation = :error
    example.run
  ensure
    PgComposite.configuration.schema_validation = previous
  end

  def model_for(value_class = @value_class, attribute: :dimensions)
    type = PgComposite::Type.new(value_class: value_class)
    Class.new(SchemaValidationBase) do
      self.table_name = 'validation_items'
      attribute attribute, type
    end
  end

  def reversed_value
    Class.new(PgComposite::Value) do
      self.sql_type = 'pg_temp.validation_dimensions'
      member :height
      member :width
    end
  end

  def validation_queries
    queries = []
    subscriber = ->(*args) { queries << args.last[:sql] if args.last[:name] == 'PgComposite schema validation' }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { yield }
    queries
  end

  it 'validates normal assignment and persistence automatically' do
    model = model_for
    record = model.create!(dimensions: { width: 10, height: 20 })
    expect(record.reload.dimensions.to_h).to eq(width: 10.0, height: 20.0)
  end

  it 'rejects reordered members before a record can be written' do
    model = model_for(reversed_value)
    expect { model.create!(dimensions: { width: 10, height: 20 }) }
      .to raise_error(PgComposite::SchemaMismatch, /Ruby declares.*height.*width.*PostgreSQL declares.*width.*height/)
  end

  it 'validates query-only use' do
    model = model_for(reversed_value)
    expect { model.where(dimensions: { width: 10 }).to_sql }.to raise_error(PgComposite::SchemaMismatch)
  end

  it 'rejects a column using a different composite with the same layout' do
    expect { model_for(attribute: :other).new }.to raise_error(PgComposite::SchemaMismatch, /column "other" uses/)
  end

  it 'does not query the catalog for ordinary models or virtual attributes' do
    plain = Class.new(SchemaValidationBase) { self.table_name = 'validation_items' }
    virtual = model_for(attribute: :preview)
    expect(validation_queries { plain.new; virtual.new }).to be_empty
  end

  it 'skips validation in none mode' do
    PgComposite.configuration.schema_validation = :none
    expect(validation_queries { model_for(reversed_value).new }).to be_empty
  end

  it 'warns once and allows access in warn mode' do
    PgComposite.configuration.schema_validation = :warn
    model = model_for(reversed_value)
    output = StringIO.new
    previous_logger = SchemaValidationBase.logger
    SchemaValidationBase.logger = ActiveSupport::Logger.new(output)
    2.times { model.new }
    expect(output.string.scan(/Ruby declares/).size).to eq(1)
  ensure
    SchemaValidationBase.logger = previous_logger
  end

  it 'checks each declaration once until the model schema is reset' do
    model = model_for
    expect(validation_queries { 3.times { model.new } }.size).to eq(1)
    model.reset_column_information
    expect(validation_queries { model.new }.size).to eq(1)
  end

  it 'validates again after the mode changes from none to error' do
    model = model_for(reversed_value)
    PgComposite.configuration.schema_validation = :none
    model.new
    PgComposite.configuration.schema_validation = :error
    expect { model.new }.to raise_error(PgComposite::SchemaMismatch)
  end

  it 'validates again when members change' do
    value = Class.new(@value_class)
    model = model_for(value)
    model.new
    value.member :depth
    expect { model.new }.to raise_error(PgComposite::SchemaMismatch, /depth/)
  end

  it 'validates inherited attributes' do
    parent = model_for(reversed_value)
    child = Class.new(parent)
    expect { child.new }.to raise_error(PgComposite::SchemaMismatch)
  end

  it 'does not access a connection when constructing types or values' do
    expect(SchemaValidationBase.connection_pool).not_to receive(:with_connection)
    type = PgComposite::Type.new(value_class: @value_class)
    expect(type.cast(width: 10).width).to eq(10.0)
    model_for
  end

  it 'rechecks the database after a schema reset' do
    model = model_for
    model.new
    @connection.execute('ALTER TYPE pg_temp.validation_dimensions ADD ATTRIBUTE depth float8')
    model.reset_column_information
    expect { model.new }.to raise_error(PgComposite::SchemaMismatch, /depth/)
  ensure
    @connection.execute('ALTER TYPE pg_temp.validation_dimensions DROP ATTRIBUTE depth')
  end

  it 'rechecks after the connection search path changes' do
    model = model_for
    model.new
    previous_path = @connection.schema_search_path
    @connection.schema_search_path = 'pg_temp, public'
    expect(validation_queries { model.new }.size).to eq(1)
  ensure
    @connection.schema_search_path = previous_path
  end

  it 'does not reuse validation from another physical connection' do
    model = model_for
    model.new
    stub_const('OtherValidationBase', Class.new(ActiveRecord::Base) { self.abstract_class = true })
    OtherValidationBase.establish_connection(ENV.fetch('TEST_DATABASE_URL', 'postgresql:///postgres'))
    other = OtherValidationBase.connection
    other.execute('CREATE TEMP TABLE validation_namespace (id integer)')
    other.execute('CREATE TYPE pg_temp.validation_dimensions AS (height float8, width float8)')
    other.execute('CREATE TEMP TABLE validation_items (id bigint, dimensions pg_temp.validation_dimensions)')
    allow(model).to receive(:connection_pool).and_return(OtherValidationBase.connection_pool)
    expect { model.new }.to raise_error(PgComposite::SchemaMismatch, /PostgreSQL declares.*height.*width/)
  ensure
    OtherValidationBase.connection_pool.disconnect! if defined?(OtherValidationBase)
  end

end
