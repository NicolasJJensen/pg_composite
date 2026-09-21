require 'pg_composite'
require_relative 'support/color'
require 'action_controller'
require 'action_controller/test_case'

RSpec.describe PgComposite do
  before(:all) do
    ActiveRecord::Base.establish_connection(ENV.fetch('TEST_DATABASE_URL', 'postgresql:///postgres'))
    @connection = ActiveRecord::Base.connection
    @connection.execute('CREATE TEMP TABLE composite_namespace (id integer)')
    @connection.execute('CREATE TYPE pg_temp.test_color AS (lightness float8, color float8, hue float8, alpha float8)')
    @connection.execute('CREATE TEMP TABLE composite_items (id bigserial PRIMARY KEY, name text, color pg_temp.test_color, metadata jsonb)')
    register_composite_oid('pg_temp.test_color')
    stub_type = PgComposite::Type.new(value_class: ExampleColors::OklchColor, sql_type: 'pg_temp.test_color')
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = 'composite_items'
      attribute :color, stub_type
    end
    Object.const_set(:CompositeItem, klass)
  end
  after(:all) do
    ActiveRecord::Base.connection_pool.disconnect!
    Object.send(:remove_const, :CompositeItem)
  end
  # Rails has no type-map entry for a composite OID, so the first read of the column warns
  # "unknown OID ...". Register the same fallback the adapter installs after that warning,
  # which keeps the raw record string that PgComposite::Type parses.
  def register_composite_oid(type_name)
    type_map = @connection.respond_to?(:type_map, true) ? @connection.send(:type_map) : nil
    return unless type_map.respond_to?(:register_type)
    oid = @connection.select_value("SELECT '#{type_name}'::regtype::oid").to_i
    type_map.register_type(oid, ActiveRecord::Type.default_value)
  end

  before { CompositeItem.delete_all }

  let(:color) { { lightness: 0.7, chroma: 0.15, hue: 180, alpha: 1 } }
  let!(:item) { CompositeItem.create!(name: 'first', color: color, metadata: { 'x' => 1 }) }

  it 'casts string keys and numbers, serializes and reloads without false dirty changes' do
    item.color = color.transform_keys(&:to_s).transform_values(&:to_s)
    expect(item.color.hue).to eq(180.0)
    item.save!
    item.reload
    expect(item.color.to_h).to eq(color)
    expect(item.will_save_change_to_color?).to be(false)
    item.color.hue = 250
    expect(item.will_save_change_to_color?).to be(true)
    item.save!
    expect(item.reload.color.hue).to eq(250.0)
  end

  it 'accepts an application-defined value object directly on create' do
    value = ExampleColors::OklchColor.new(color)
    row = CompositeItem.create!(color: value)
    expect(row.reload.color).to eq(value)
    expect(defined?(PgComposite::OklchColor)).to be_nil
  end

  it 'compares selected members, preserving ordinary columns and JSON queries' do
    CompositeItem.create!(name: 'second', color: color.merge(hue: 90))
    expect(CompositeItem.where(color: { hue: 180, chroma: 0.15 }).pluck(:id)).to eq([item.id])
    expect(CompositeItem.where(name: 'first', metadata: { x: 1 }).pluck(:id)).to eq([item.id])
  end

  it 'supports ranges, arrays, null and empty lists on members' do
    null_item = CompositeItem.create!(color: color.merge(hue: nil))
    expect(CompositeItem.where(color: { hue: 170...181 }).pluck(:id)).to eq([item.id])
    expect(CompositeItem.where(color: { hue: [180, nil] }).order(:id).pluck(:id)).to eq([item.id, null_item.id])
    expect(CompositeItem.where(color: { hue: nil }).pluck(:id)).to eq([null_item.id])
    expect(CompositeItem.where(color: { hue: [] })).to be_empty
    expect(CompositeItem.where(color: { hue: 180.. }).pluck(:id)).to eq([item.id])
  end

  it 'compares whole typed values with automatic PostgreSQL casting' do
    object = ExampleColors::OklchColor.new(color)
    expect(CompositeItem.where(color: object).pluck(:id)).to eq([item.id])
    expect(CompositeItem.where(CompositeItem.arel_table[:color].eq(object)).pluck(:id)).to eq([item.id])
    expect(CompositeItem.where.not(color: object)).to be_empty
    empty = CompositeItem.create!(color: nil)
    expect(CompositeItem.where(color: nil).pluck(:id)).to eq([empty.id])
  end

  it 'builds typed chained Arel predicates, ordering and scalar selections' do
    table = CompositeItem.arel_table
    member = table[:color][:hue]
    query = CompositeItem.where(member.gteq('180')).order(member.desc)
    expect(query.pluck(:id)).to eq([item.id])
    row = query.select(:id, member.as('color_hue')).first
    expect(row.color_hue).to eq(180.0)
    expect(row.color_hue).to be_a(Float)
    expect(query.pluck(member)).to eq([180.0])
  end

  it 'handles aliased tables and attribute aliases' do
    CompositeItem.alias_attribute :paint, :color
    expect(CompositeItem.where(CompositeItem.arel_table[:paint][:hue].eq(180)).pluck(:id)).to eq([item.id])
    aliased = CompositeItem.arel_table.alias('painted')
    expect(CompositeItem.from(aliased).where(aliased[:color][:hue].eq(180)).pluck(aliased[:id])).to eq([item.id])
  end

  it 'rejects unknown members and leaves untyped Arel tables alone' do
    expect { CompositeItem.where(color: { nope: 1 }).to_sql }.to raise_error(ArgumentError, /Unknown/)
    expect { CompositeItem.where(color: {}).to_sql }.to raise_error(ArgumentError, /empty/)
    expect(Arel::Table.new(:plain)[:id]).to be_a(Arel::Attributes::Attribute)
    expect { ExampleColors::OklchColor.new(hue: 'oops') }.to raise_error(ArgumentError)
  end
end

RSpec.describe PgComposite::Parameters do
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include PgComposite::Parameters
      cast_parameter [:service_industry, :color], type: ExampleColors::OklchColorType.new,
        permit: %i[lightness chroma hue alpha], only: :create
      def create
        values = typed_parameters(:service_industry, permit: [:name])
        render json: { hue: params[:service_industry][:color].hue, typed: values['color'].is_a?(ExampleColors::OklchColor), keys: values.keys }
      end
    end
  end

  def dispatch(input)
    request = ActionController::TestRequest.create(controller_class)
    request.set_header('action_dispatch.request.request_parameters', input)
    response = ActionDispatch::TestResponse.new
    controller_class.new.dispatch(:create, request, response)
    response
  end

  it 'replaces params before the action and merges only filtered typed attributes' do
    response = dispatch('service_industry' => { 'name' => 'Test', 'admin' => true, 'color' => { 'hue' => '180', 'evil' => 'ignored' } })
    expect(JSON.parse(response.body)).to eq('hue' => 180.0, 'typed' => true, 'keys' => ['name', 'color'])
  end

  it 'rejects malformed objects and invalid numeric input' do
    expect { dispatch('service_industry' => { 'color' => 'raw' }) }.to raise_error(ActionController::BadRequest)
    expect { dispatch('service_industry' => { 'color' => { 'hue' => 'bad' } }) }.to raise_error(ActionController::BadRequest)
  end
end
