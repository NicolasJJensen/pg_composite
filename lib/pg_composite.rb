require "active_record"
require "pg"
require_relative "pg_composite/version"
require_relative "pg_composite/configuration"
require_relative "pg_composite/value"
require_relative "pg_composite/type"
require_relative "pg_composite/arel"
require_relative "pg_composite/parameters"
require_relative "pg_composite/schema"
require_relative "pg_composite/model_schema"

# Deferred so that requiring the gem does not pull ActiveRecord::PredicateBuilder
# out of its autoload before the application is ready for it.
ActiveSupport.on_load(:active_record) do
  singleton_class.prepend(PgComposite::ModelSchema)
  Arel::Table.prepend(PgComposite::TableAccess)
  Arel::Nodes::TableAlias.prepend(PgComposite::TableAccess)
  Arel::Visitors::ToSql.include(PgComposite::UnsupportedVisitor)
  Arel::Visitors::PostgreSQL.include(PgComposite::Visitor)
  ActiveRecord::PredicateBuilder.prepend(PgComposite::Predicates)
end
