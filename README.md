# PgComposite

Use Ruby objects for PostgreSQL composite columns. Define the members of your value, assign it to an Active Record attribute, and work with it through ordinary model assignment and queries.

**This gem is PostgreSQL-only.** It generates PostgreSQL composite-type SQL and has no fallback for other databases. On any other adapter the composite nodes raise `PgComposite::UnsupportedAdapter` instead of building SQL.

The example below stores a color as one column containing lightness, chroma, hue, and alpha. `OklchColor` is a class you define in your application.

## Installation

Add the gem to your application's Gemfile and run `bundle install`:

```ruby
gem "pg_composite"
```

Requires Ruby 3.1+, Active Record 7.0 through 8.x, and PostgreSQL. Controller
parameter casting also needs Action Pack.
The suite runs green on Active Record 7.0, 7.1, 7.2, 8.0, and 8.1.

## How it hooks in

Loading the gem patches Arel and Active Record. There is no opt-in step and no
configuration flag. Requiring the gem installs all of it, and Bundler does that
require for you. The patches run inside `ActiveSupport.on_load(:active_record)`,
so they apply when Active Record loads rather than when the gem is required.

| Target | How | What it changes |
| --- | --- | --- |
| `Arel::Table` | `prepend` | `[]` returns a `PgComposite::Column` for attributes typed as a composite |
| `Arel::Nodes::TableAlias` | `prepend` | the same `[]` behaviour on an aliased table |
| `Arel::Visitors::PostgreSQL` | `include` | visitors for the composite column, member, and cast nodes |
| `Arel::Visitors::ToSql` | `include` | the same three visitors, raising `PgComposite::UnsupportedAdapter` on every other adapter |
| `ActiveRecord::PredicateBuilder` | `prepend` | registers a `Hash` handler so `where(color: { hue: 180 })` compares members |

Each patch falls back to the original behaviour for anything that is not a composite
attribute, so ordinary tables, columns, and `where` hashes keep working as before.

## Setup

### 1. Create the PostgreSQL type

Skip this migration if the type already exists.

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

### 2. Use the type in a table

Create a separate migration for the table. For an existing table, add the column instead.

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

Set `config.active_record.schema_format = :sql` in `config/application.rb` to preserve the PostgreSQL type definition in schema dumps.

### 3. Define the Ruby value

Declare members in the same order as the database type:

```ruby
# app/models/oklch_color.rb
class OklchColor < PgComposite::Value
  self.sql_type = "oklch_color"

  member :lightness, type: :float, default: 0.0
  member :chroma,    type: :float, default: 0.0
  member :hue,       type: :float, default: 0.0
  member :alpha,     type: :float, default: 1.0
end
```

| `member` option | Purpose | Default |
| --- | --- | --- |
| `type:` | The Active Model scalar type used to cast the value. | `:float` |
| `default:` | Value used when that member is omitted from a hash. | `nil` |
| `column:` | Database member name, if it differs from the Ruby name. | The Ruby name |

For example, `member :chroma, column: :color` maps Ruby's `chroma` to a database member named `color`.

### 4. Define a reusable attribute type

Pair the value class with a type that you can reuse across models and form objects:

```ruby
# app/types/oklch_color_type.rb
class OklchColorType < PgComposite::Type
  self.subtype = OklchColor
end
```

Declare each attribute with that type:

```ruby
class ServiceIndustry < ApplicationRecord
  attribute :color, OklchColorType.new
end
```

For a one-off declaration, `PgComposite::Type.new(value_class: OklchColor)` works too.

## Creating and updating records

Pass a value object directly:

```ruby
color = OklchColor.new(lightness: 0.7, chroma: 0.15, hue: 180, alpha: 1)
industry = ServiceIndustry.create!(name: "Design", color: color)

industry.reload.color.hue # => 180.0
```

Or assign a hash. String keys and numeric strings are cast automatically:

```ruby
industry.update!(color: { "lightness" => "0.7", "hue" => "250" })
industry.color.hue # => 250.0
```

A hash constructs a complete value using defaults for omitted members. To change one member while retaining the others:

```ruby
industry.color.hue = 120
industry.save!
```

Assigning `nil` clears the entire column. Explicit nil or empty-string members become nil. Use `industry.color.to_h` when you need a hash, such as for a JSON response. Add application validations for domain rules such as allowed color ranges.

## Querying

A hash matches only the members you supply:

```ruby
ServiceIndustry.where(color: { hue: 180 })
ServiceIndustry.where(color: { hue: 170...190, alpha: 1 })
ServiceIndustry.where(color: { hue: [90, 180, 270] })
```

A value object compares the whole color:

```ruby
ServiceIndustry.where(color: color)
ServiceIndustry.where.not(color: color)
```

For other comparisons and ordering, access members through Arel:

```ruby
hue = ServiceIndustry.arel_table[:color][:hue]
ServiceIndustry.where(hue.gteq(180)).order(hue.asc)
```

You can select individual members too:

```ruby
industry = ServiceIndustry.select(:id, hue.as("color_hue")).first
industry.color_hue # => a Float

ServiceIndustry.pluck(hue) # => an array of hue values
```

Selecting a member returns a scalar, not a partial color object. Select `:color` as well when you need the full value.

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

Initialize a new record's color with `OklchColor.new` before rendering those fields. Permit the submitted members normally:

```ruby
params.require(:service_industry).permit(
  :name, color: %i[lightness chroma hue alpha]
)
```

The same attribute declaration works in a form object using `ActiveModel::Attributes`, allowing conversion before assignment to an Active Record model. Invalid numeric input raises `ArgumentError`; handle that conversion error in the form if you want inline feedback.

### Typed values directly in params

Optionally include the parameter concern to convert a declared parameter before the action reads it:

```ruby
class ServiceIndustriesController < ApplicationController
  include PgComposite::Parameters

  cast_parameter [:service_industry, :color],
    type: OklchColorType.new,
    permit: %i[lightness chroma hue alpha],
    only: %i[create update]

  def create
    params[:service_industry][:color] # => an OklchColor
    industry = ServiceIndustry.create!(
      typed_parameters(:service_industry, permit: [:name])
    )
    redirect_to industry
  end
end
```

Use `typed_parameters` instead of filtering the converted object with ordinary nested `permit`. It combines permitted ordinary fields with the already-filtered typed values. Missing color parameters remain missing; malformed supplied values produce a bad-request error.

## Development

Run `bundle install`, then `bundle exec rspec`. Tests use PostgreSQL temporary tables; set `TEST_DATABASE_URL` if needed (default: `postgresql:///postgres`). Include a regression test with behavior changes.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/NicolasJJensen/pg_composite.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
