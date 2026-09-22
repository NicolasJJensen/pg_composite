module PgComposite
  class Configuration
    def schema_validation
      return @schema_validation if defined?(@schema_validation)

      if defined?(Rails) && Rails.respond_to?(:env)
        %w[development test].include?(Rails.env.to_s) ? :error : :none
      else
        :error
      end
    end

    def schema_validation=(mode)
      unless %i[error warn none].include?(mode)
        raise ArgumentError, "schema_validation must be :error, :warn, or :none"
      end
      @schema_validation = mode
    end
  end

  def self.configuration
    @configuration ||= Configuration.new
  end

  def self.configure
    yield configuration
  end
end
