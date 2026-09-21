require 'pg_composite'
require_relative 'support/color'
require 'sqlite3'

RSpec.describe 'PgComposite on a non-PostgreSQL adapter' do
  before(:all) do
    Object.const_set(:GuardBase, Class.new(ActiveRecord::Base) { self.abstract_class = true })
    GuardBase.establish_connection(adapter: 'sqlite3', database: ':memory:')
    GuardBase.connection.create_table(:guard_items) do |t|
      t.string :name
      t.string :color
    end
    stub_type = PgComposite::Type.new(value_class: ExampleColors::OklchColor, sql_type: 'test_color')
    Object.const_set(:GuardItem, Class.new(GuardBase) do
      self.table_name = 'guard_items'
      attribute :color, stub_type
    end)
  end

  after(:all) do
    GuardBase.connection_pool.disconnect!
    Object.send(:remove_const, :GuardItem)
    Object.send(:remove_const, :GuardBase)
  end

  let(:table) { GuardItem.arel_table }
  let(:message) { /pg_composite requires the PostgreSQL adapter \(connection is SQLite\)/ }

  it 'raises for a member where hash' do
    expect { GuardItem.where(color: { lightness: 0.7 }).to_sql }
      .to raise_error(PgComposite::UnsupportedAdapter, message)
  end

  it 'raises for a member range and a member list' do
    expect { GuardItem.where(color: { hue: 10..20 }).to_sql }.to raise_error(PgComposite::UnsupportedAdapter)
    expect { GuardItem.where(color: { hue: [10, 20] }).to_sql }.to raise_error(PgComposite::UnsupportedAdapter)
  end

  it 'raises for an Arel member comparison' do
    expect { GuardItem.where(table[:color][:hue].gt(90)).to_sql }
      .to raise_error(PgComposite::UnsupportedAdapter, message)
  end

  it 'raises for a whole-value cast' do
    value = ExampleColors::OklchColor.new(lightness: 0.7, chroma: 0.15, hue: 180, alpha: 1)
    expect { GuardItem.where(table[:color].eq(value)).to_sql }
      .to raise_error(PgComposite::UnsupportedAdapter, message)
  end

  it 'leaves ordinary columns alone' do
    expect(GuardItem.where(name: 'first').to_sql).to include('"guard_items"."name"')
  end

  it 'keeps the PostgreSQL visitor ahead of the raising module' do
    member = table[:color][:hue]
    connection = GuardBase.connection
    rendered = Arel::Visitors::PostgreSQL.new(connection)
                                         .accept(member, Arel::Collectors::SQLString.new).value
    expect(rendered).to eq('("guard_items"."color")."hue"')
    expect { Arel::Visitors::SQLite.new(connection).accept(member, Arel::Collectors::SQLString.new) }
      .to raise_error(PgComposite::UnsupportedAdapter, message)
  end
end
