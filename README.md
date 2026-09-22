# PgComposite

PgComposite maps a PostgreSQL composite column to a typed Ruby value object. Assign values through Active Record and query members through hashes or Arel.

Requires Ruby 3.1+, Active Record 7.0 through 8.x, and the PostgreSQL adapter. The setup below creates the database type and column used here.

```ruby
class OklchColor < PgComposite::Value
  self.sql_type = "oklch_color"

  member :lightness, type: :float, default: 0.0
  member :chroma, type: :float, default: 0.0
  member :hue, type: :float, default: 0.0
  member :alpha, type: :float, default: 1.0
end

class ServiceIndustry < ApplicationRecord
  attribute :color, PgComposite::Type.new(value_class: OklchColor)
end

industry = ServiceIndustry.create!(
  name: "Design",
  color: OklchColor.new(lightness: 0.7, chroma: 0.15, hue: 180, alpha: 1)
)

ServiceIndustry.where(color: { hue: 180 }).first.color.hue # => 180.0
```

## Installation

Add PgComposite to your Gemfile:

```ruby
gem "pg_composite"
```

Run `bundle install`. Rails normally loads the gem through `Bundler.require`.
In a standalone Active Record application, require PgComposite explicitly:

```ruby
require "pg_composite"
```

PgComposite does not open a database connection when you require it. It also does not open a connection when you construct a value object.

The optional controller parameter concern requires Action Pack. The [compatibility workflow](https://github.com/NicolasJJensen/pg_composite/actions/workflows/compatibility.yml) tests Rails 7.0, 7.1, 7.2, 8.0, and 8.1 on supported Ruby versions.

## Getting started

### Create the PostgreSQL type

Create the composite type in a migration. Use your application's Rails migration version in place of `8.0` if needed:

```ruby
class CreateOklchColorType < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE TYPE oklch_color AS (
        lightness double precision,
        chroma double precision,
        hue double precision,
        alpha double precision
      )
    SQL
  end

  def down
    execute "DROP TYPE oklch_color"
  end
end
```

Create the table column in a separate migration:

```ruby
class CreateServiceIndustries < ActiveRecord::Migration[8.0]
  def change
    create_table :service_industries do |t|
      t.string :name
      t.column :color, :oklch_color
    end
  end
end
```

Set the SQL schema format so schema dumps preserve the PostgreSQL type definition:

```ruby
# config/application.rb
config.active_record.schema_format = :sql
```

### Define the value

Set `sql_type` to the database type name, optionally schema-qualified, such as `"public.oklch_color"`. Declare members in database order:

```ruby
# app/models/oklch_color.rb
class OklchColor < PgComposite::Value
  self.sql_type = "oklch_color"

  member :lightness, type: :float, default: 0.0
  member :chroma, type: :float, default: 0.0
  member :hue, type: :float, default: 0.0
  member :alpha, type: :float, default: 1.0
end
```

`member` accepts these options:

| Option | Purpose | Default |
| --- | --- | --- |
| `type:` | Active Model scalar type used to cast the member. | `:float` |
| `default:` | Value used when a hash omits the member. | `nil` |
| `column:` | Database member name when it differs from the Ruby name. | The Ruby name |

For example, `member :chroma, column: :color` maps Ruby member `chroma` to database member `color`. The PostgreSQL type must declare a member named `color` in the corresponding position. Schema validation checks this mapping and the declared order when enabled.

### Declare the model attribute

```ruby
class ServiceIndustry < ApplicationRecord
  attribute :color, PgComposite::Type.new(value_class: OklchColor)
end
```

## Values

Assign a value object directly:

```ruby
color = OklchColor.new(lightness: 0.7, chroma: 0.15, hue: 180, alpha: 1)
industry = ServiceIndustry.create!(name: "Design", color: color)

industry.reload.color.hue # => 180.0
```

Assign a hash when you receive attributes from a form or API. String keys and numeric strings are cast:

```ruby
industry.update!(color: { "lightness" => "0.7", "hue" => "250" })
industry.color.hue # => 250.0
```

A hash creates a complete value. Omitted members use their defaults. To change one member and keep the others, assign the member on the existing value:

```ruby
industry.color.hue = 120
industry.save!
```

Assigning `nil` clears the whole column. An explicit nil or empty string makes a member nil. Use `to_h` when you need a hash:

```ruby
industry.color.to_h
# => { lightness: 0.7, chroma: 0.0, hue: 120.0, alpha: 1.0 }
```

Malformed numeric input raises `ArgumentError`. Add application validations for rules such as allowed color ranges.

## Queries

A hash matches only the members you provide:

```ruby
ServiceIndustry.where(color: { hue: 180 })
ServiceIndustry.where(color: { hue: 170...190, alpha: 1 })
ServiceIndustry.where(color: { hue: [90, 180, 270] })
```

A value object compares the whole composite:

```ruby
ServiceIndustry.where(color: color)
ServiceIndustry.where.not(color: color)
```

Use Arel for member comparisons and ordering:

```ruby
hue = ServiceIndustry.arel_table[:color][:hue]
ServiceIndustry.where(hue.gteq(180)).order(hue.asc)
```

Select or pluck a member when you need a scalar:

```ruby
industry = ServiceIndustry.select(:id, hue.as("color_hue")).first
industry.color_hue # => a Float

ServiceIndustry.pluck(hue) # => an array of hue values
```

Selecting a member returns a scalar. Select `:color` as well when you need the full value object.

## Forms

Nested fields submit a hash that the model attribute can cast:

```erb
<%= form_with model: industry do |f| %>
  <%= f.fields_for :color, industry.color do |color_fields| %>
    <%= color_fields.number_field :hue %>
  <% end %>
  <%= f.submit %>
<% end %>
```

Initialize a new record's color before rendering nested fields:

```ruby
industry = ServiceIndustry.new(color: OklchColor.new)
```

Permit submitted members as ordinary nested parameters:

```ruby
params.require(:service_industry).permit(
  :name, color: %i[lightness chroma hue alpha]
)
```

The same attribute declaration works in a form object that includes `ActiveModel::Attributes`. It casts the form value before you assign it to an Active Record model. Handle numeric conversion errors in your form for inline feedback.

### Optional controller parameter casting

Include `PgComposite::Parameters` when you want a controller callback to cast a declared parameter before the action runs:

```ruby
class ServiceIndustriesController < ApplicationController
  include PgComposite::Parameters

  cast_parameter [:service_industry, :color],
    type: PgComposite::Type.new(value_class: OklchColor),
    permit: %i[lightness chroma hue alpha],
    only: %i[create update]

  def create
    params[:service_industry][:color] # => an OklchColor
    industry = ServiceIndustry.create!(
      params.require(:service_industry).permit(:name, :color)
    )
    redirect_to industry
  end
end
```

The callback filters the color members using its `permit:` list, then replaces the nested parameters with an `OklchColor` object.
PgComposite registers `PgComposite::Value` and its subclasses as permitted scalars when Action Controller loads. Ordinary `permit(:name, :color)` retains the converted object.

Use `:color` in the action's permit list to allow the whole typed value. Nested `permit(color: [:hue])` does not inspect a converted object.
Omitting `:color` from the action's permit list excludes it, even if the callback already converted it.

Missing color parameters remain missing. A supplied string, array, or `nil` instead of an object raises `ActionController::BadRequest`.
Invalid numeric input also raises `ActionController::BadRequest`. Without `cast_parameter`, use ordinary nested strong parameters and let the model cast the permitted hash.

## Schema validation

PgComposite automatically checks persisted composite attributes when Active Record initializes a model's attribute types. You do not need to add a validation call.

The check confirms that the composite type exists and that member names, count, and order match. It also checks that the table column uses the declared composite type.

PgComposite does not compare the scalar types of individual members. Keep Ruby member types compatible with their database fields.

Automatic checks apply to persisted Active Record attributes. Standalone values and virtual attributes have no table column to validate.

Configure the check in an environment file or an initializer:

```ruby
# config/environments/development.rb
PgComposite.configure do |config|
  config.schema_validation = :error
end
```

The available modes are:

| Mode | Behavior |
| --- | --- |
| `:error` | Raise `PgComposite::SchemaMismatch` when the declaration does not match PostgreSQL. |
| `:warn` | Log the mismatch and continue. Incorrect writes may continue. |
| `:none` | Skip schema catalog queries. |

The default is `:error` in Rails development and test environments, and `:none` in other Rails environments. Standalone Active Record applications use `:error` by default. Production uses `:none` unless you set another mode.

PgComposite performs the automatic check once for each connection, schema, and declaration context. Call `Model.reset_column_information` after changing a database type in a running process. This invalidates prior checks. Development class reloads also discard the checks. Requiring PgComposite and constructing a value do not trigger a connection or a catalog query.

To check a declaration directly, call the type method with a connection:

```ruby
PgComposite::Type.new(value_class: OklchColor).validate_schema!(
  connection: ActiveRecord::Base.connection
)
```

The explicit check validates the named composite and its members. It does not check a model column.

`validate_schema!` always raises `PgComposite::SchemaMismatch` for a mismatch, regardless of `schema_validation`.

## API reference

### `PgComposite::Value`

- `self.sql_type = name` declares the PostgreSQL composite type.
- `member(name, type: :float, column: name, default: nil)` declares a member.
- `new` accepts a hash, positional array, PostgreSQL record string, or another value of the same class. It casts each member.
- `to_h` returns a symbol-keyed hash.
- `serialize` returns PostgreSQL record text.

### `PgComposite::Type`

- `PgComposite::Type.new(value_class:, sql_type: nil)` creates an Active Model type.
- `self.subtype = ValueClass` sets the default value class for a subclass.
- `cast`, `serialize`, and `deserialize` integrate with Active Record attributes.
- `validate_schema!(connection:)` checks the declaration and raises `PgComposite::SchemaMismatch` on mismatch.

For a type shared across models or form objects, define a subclass:

```ruby
# app/types/oklch_color_type.rb
class OklchColorType < PgComposite::Type
  self.subtype = OklchColor
end

# In a model or form object:
attribute :color, OklchColorType.new
```

### Configuration

- `PgComposite.configure { |config| ... }` changes global configuration.
- `config.schema_validation` accepts `:error`, `:warn`, or `:none`.

### `PgComposite::Parameters`

- `cast_parameter(path, type:, permit:, **callback_options)` registers a controller callback.

## Internals

PgComposite extends Active Record and Arel when Active Record loads. Composite attributes return PgComposite Arel nodes for columns and members. PostgreSQL visitors render those nodes as composite SQL. The predicate builder handles member hashes such as `where(color: { hue: 180 })`.

When Action Controller loads, PgComposite adds its value base class to Rails' global permitted-scalar list. This includes application-defined composite subclasses.

The patches preserve ordinary Active Record behavior for non-composite attributes. Non-PostgreSQL visitors raise `PgComposite::UnsupportedAdapter` when they receive a composite node.

## Development

Run `bundle install`, then run:

```sh
bundle exec rspec
```

The suite needs a running PostgreSQL server and permission to create test schemas and types. It removes its test schemas afterward.
Set `TEST_DATABASE_URL` when the default `postgresql:///postgres` connection is not available. SQLite tests verify unsupported-adapter behavior.

To test a specific Rails version:

```sh
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_7_2.gemfile bundle exec rspec
```

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/NicolasJJensen/pg_composite).

## License

PgComposite is available under the [MIT License](https://opensource.org/licenses/MIT).
