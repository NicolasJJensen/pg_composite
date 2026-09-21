module PgComposite
  class Cast < Arel::Nodes::Unary
    attr_reader :sql_type
    def initialize(value, sql_type)
      super(value)
      @sql_type = sql_type
    end
  end

  RangeWithBinds = Struct.new(:begin, :end, :exclude_end?)

  class Column < Arel::Attributes::Attribute
    def [](member)
      definition = type_caster.members.fetch(member.to_s) do
        raise ArgumentError, "Unknown composite member: #{member}"
      end
      Member.new(self, definition)
    end

    def eq(value)
      return super if value.nil? || (value.respond_to?(:value_before_type_cast) && value.value_before_type_cast.nil?)
      quoted = Arel::Nodes.build_quoted(value, self)
      super(Cast.new(quoted, type_caster.sql_type))
    end

    def not_eq(value)
      return super if value.nil? || (value.respond_to?(:value_before_type_cast) && value.value_before_type_cast.nil?)
      super(Cast.new(Arel::Nodes.build_quoted(value, self), type_caster.sql_type))
    end
  end

  class Member < Arel::Attributes::Attribute
    attr_reader :parent
    def initialize(parent, definition)
      super(parent.relation, definition[:column])
      @parent, @member_type = parent, definition[:type]
    end
    def type_caster = @member_type
    def able_to_type_cast? = true
    def type_cast_for_database(value) = @member_type.serialize(value)
  end

  module TableAccess
    def [](name, *args)
      attribute = super
      attribute.type_caster.is_a?(Type) ? Column.new(attribute.relation, attribute.name) : attribute
    rescue NoMethodError => error
      # Bare Arel tables do not carry a model's type metadata.
      raise unless attribute && !attribute.able_to_type_cast?
      attribute
    end
  end

  class UnsupportedAdapter < StandardError; end

  # Included into Arel::Visitors::ToSql. PgComposite::Visitor sits higher in the ancestors of
  # Arel::Visitors::PostgreSQL, so PostgreSQL keeps the real methods and every other adapter
  # reaches these instead of rendering a composite node as a bare column.
  module UnsupportedVisitor
    def visit_PgComposite_Column(_node, _collector) = pg_composite_unsupported!
    def visit_PgComposite_Member(_node, _collector) = pg_composite_unsupported!
    def visit_PgComposite_Cast(_node, _collector) = pg_composite_unsupported!

    private

    def pg_composite_unsupported!
      adapter = @connection.respond_to?(:adapter_name) ? @connection.adapter_name : "unknown"
      raise UnsupportedAdapter, "pg_composite requires the PostgreSQL adapter (connection is #{adapter})"
    end
  end

  module Visitor
    def visit_PgComposite_Column(node, collector)
      visit_Arel_Attributes_Attribute(node, collector)
    end
    def visit_PgComposite_Member(node, collector)
      collector << "("
      visit(node.parent, collector)
      collector << ")." << quote_column_name(node.name)
    end
    def visit_PgComposite_Cast(node, collector)
      collector << "CAST("
      visit(node.expr, collector)
      collector << " AS " << node.sql_type.split(".").map { |part| quote_column_name(part) }.join(".") << ")"
    end
  end

  module Predicates
    def initialize(table)
      super
      fallback = handler_for({})
      register_handler(Hash, lambda do |attribute, values|
        unless attribute.type_caster.is_a?(Type)
          next fallback.call(attribute, values)
        end
        raise ArgumentError, "Composite member predicates cannot be empty" if values.empty?
        predicates = values.map do |name, value|
          member = attribute[name]
          bind = ->(item) { ActiveRecord::Relation::QueryAttribute.new(member.name, item, member.type_caster) }
          case value
          when Range
            member.between(RangeWithBinds.new(bind.call(value.begin), bind.call(value.end), value.exclude_end?))
          when Array
            non_null = value.compact.map { |item| bind.call(item) }
            predicate = member.in(non_null)
            value.include?(nil) ? predicate.or(member.eq(nil)) : predicate
          else
            member.eq(bind.call(value))
          end
        end
        Arel::Nodes::And.new(predicates)
      end)
    end
  end
end
