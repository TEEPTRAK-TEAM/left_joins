require "left_joins/version"
require 'active_record'
require 'active_record/relation'
require 'active_record/relation/merger'

module ActiveRecord::QueryMethods
  IS_RAILS3_FLAG = Gem::Version.new(ActiveRecord::VERSION::STRING) < Gem::Version.new('4.0.0')

  # ----------------------------------------------------------------
  # ● Implement check_if_method_has_arguments! method for Rails 3
  # ----------------------------------------------------------------
  if IS_RAILS3_FLAG
    def check_if_method_has_arguments!(method_name, args)
      if args.blank?
        raise ArgumentError, "The method .#{method_name}() must contain arguments."
      end
    end
  end
  if not method_defined?(:left_outer_joins!)
    # ----------------------------------------------------------------
    # ● Storing left joins values into @left_outer_joins_values
    # ----------------------------------------------------------------
    attr_reader :left_outer_joins_values
    def left_outer_joins(*args)
      check_if_method_has_arguments!(:left_outer_joins, args)

      args.compact!
      args.flatten!

      return (IS_RAILS3_FLAG ? clone : spawn).left_outer_joins!(*args)
    end

    def left_outer_joins!(*args)
      (@left_outer_joins_values ||= []) << args
      self
    end

    # ----------------------------------------------------------------
    # ● Implement left joins when building arel
    # ----------------------------------------------------------------
    alias_method :left_joins, :left_outer_joins
    alias_method :build_arel_without_outer_joins, :build_arel
    def build_arel(*args)
      arel = build_arel_without_outer_joins(*args)
      build_left_outer_joins(arel, @left_outer_joins_values.flatten) if @left_outer_joins_values
      return arel
    end

    alias_method :build_joins_without_join_type, :build_joins
    def build_joins(manager, joins, join_type = Arel::Nodes::InnerJoin)
      Thread.current.thread_variable_set :left_joins_join_type, join_type
      result = build_joins_without_join_type(manager, joins)
      Thread.current.thread_variable_set :left_joins_join_type, nil
      return result
    end

    def build_left_outer_joins(manager, joins)
      result = build_joins(manager, joins, Arel::Nodes::OuterJoin)
      return result
    end

    class << ::ActiveRecord::Base
      def left_joins(*args)
        self.where('').left_joins(*args)
      end
      alias_method :left_outer_joins, :left_joins
    end

    class ::ActiveRecord::Associations::JoinDependency
      if IS_RAILS3_FLAG
        alias_method :build_without_hooking_join_type, :build
        def build(associations, parent = nil, join_type = Arel::Nodes::InnerJoin)
          join_type = Thread.current.thread_variable_get :left_joins_join_type || join_type
          return build_without_hooking_join_type(associations, parent, join_type)
        end
      else
        alias_method :make_constraints_without_hooking_join_type, :make_constraints
        def make_constraints(*args, join_type)
          join_type = Thread.current.thread_variable_get :left_joins_join_type || join_type
          return make_constraints_without_hooking_join_type(*args, join_type)
        end
      end
    end

    module ActiveRecord::Calculations
      def perform_calculation(operation, column_name, options = {})
        operation = operation.to_s.downcase

        # If #count is used with #distinct (i.e. `relation.distinct.count`) it is
        # considered distinct.
        distinct = IS_RAILS3_FLAG ? options[:distinct] || self.uniq_value : self.distinct_value

        if operation == "count"
          column_name ||= select_for_count
          column_name = primary_key if column_name == :all && distinct
          distinct = nil if column_name =~ /\s*DISTINCT[\s(]+/i
        end

        if group_values.any?
          execute_grouped_calculation(operation, column_name, distinct)
        else
          execute_simple_calculation(operation, column_name, distinct)
        end
      end
    end
  end
end

# ----------------------------------------------------------------
# ● Implement left joins when merging relations
# ----------------------------------------------------------------
class ActiveRecord::Relation::Merger
  alias_method :merge_joins_without_left_joins, :merge_joins
  def merge_joins
    merge_joins_without_left_joins
    return if other.left_outer_joins_values.blank?
    
    if other.klass == relation.klass
      relation.left_outer_joins!(*other.left_outer_joins_values)
    else
      alias_tracker = nil
      joins_dependency = other.left_outer_joins_values.map do |join|
        case join
        when Hash, Symbol, Array
          alias_tracker ||= other.alias_tracker
          ActiveRecord::Associations::JoinDependency.new(
            other.klass, other.table, join, alias_tracker
          )
        else
          join
        end
      end

      relation.left_outer_joins!(*joins_dependency)
    end
  end
end

