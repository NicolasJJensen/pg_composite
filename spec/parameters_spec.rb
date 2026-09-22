require 'open3'
require 'rbconfig'
require 'action_controller'
require 'action_controller/test_case'
require 'pg_composite'
require_relative 'support/color'

RSpec.describe 'PgComposite parameter casting' do
  def controller_for(base, permitted_keys: %i[name color])
    keys = permitted_keys
    Class.new(base) do
      include PgComposite::Parameters
      cast_parameter %i[service_industry color], type: ExampleColors::OklchColorType.new,
        permit: %i[lightness chroma hue alpha], only: :create

      define_method(:create) do
        permitted = params.require(:service_industry).permit(*keys)
        color = permitted[:color]
        render json: {
          keys: permitted.keys,
          name: permitted[:name],
          color_class: color&.class&.name,
          color_hue: color&.hue,
          same_object: color && color.equal?(params[:service_industry][:color])
        }
      end
    end
  end

  def dispatch(controller_class, input)
    request = ActionController::TestRequest.create(controller_class)
    request.set_header('action_dispatch.request.request_parameters', input)
    response = ActionDispatch::TestResponse.new
    controller_class.new.dispatch(:create, request, response)
    response
  end

  let(:color) { { lightness: '0.7', chroma: '0.15', hue: '180', alpha: '1', ignored: 'x' } }

  it 'filters and casts values in ActionController::Base' do
    response = dispatch(controller_for(ActionController::Base), 'service_industry' => {
      'name' => 'Test', 'admin' => true, 'color' => color
    })

    expect(JSON.parse(response.body)).to include(
      'keys' => %w[name color], 'name' => 'Test',
      'color_class' => 'ExampleColors::OklchColor', 'color_hue' => 180.0, 'same_object' => true
    )
  end

  it 'filters and casts values in ActionController::API' do
    response = dispatch(controller_for(ActionController::API), 'service_industry' => {
      'name' => 'Test', 'color' => color
    })

    expect(JSON.parse(response.body)).to include('color_class' => 'ExampleColors::OklchColor', 'same_object' => true)
  end

  it 'drops the cast value when the action omits color from permit' do
    response = dispatch(controller_for(ActionController::Base, permitted_keys: [:name]), 'service_industry' => {
      'name' => 'Test', 'color' => color
    })

    expect(JSON.parse(response.body)).to include('keys' => ['name'], 'color_class' => nil)
  end

  it 'permits the parent without color when color is missing' do
    response = dispatch(controller_for(ActionController::Base), 'service_industry' => { 'name' => 'Test' })

    expect(JSON.parse(response.body)).to include('keys' => ['name'], 'color_class' => nil)
  end

  it 'rejects malformed color values' do
    ['raw', [], nil].each do |value|
      expect {
        dispatch(controller_for(ActionController::Base), 'service_industry' => { 'color' => value })
      }.to raise_error(ActionController::BadRequest, /Expected an object/)
    end
    expect {
      dispatch(controller_for(ActionController::Base), 'service_industry' => { 'color' => { 'hue' => 'bad' } })
    }.to raise_error(ActionController::BadRequest, /Invalid service_industry.color/)
  end

  it 'rejects an unrelated object and a raw nested hash as permitted scalars' do
    params = ActionController::Parameters.new(
      object: Object.new,
      nested: { hue: 180 },
      color: ExampleColors::OklchColor.new(hue: 180)
    )
    permitted = params.permit(:object, :nested, :color)

    expect(permitted).not_to have_key(:object)
    expect(permitted).not_to have_key(:nested)
    expect(permitted[:color]).to be_a(ExampleColors::OklchColor)
  end

  it 'treats converted values as atomic scalars rather than nested parameters' do
    params = ActionController::Parameters.new(color: ExampleColors::OklchColor.new(hue: 180))

    expect(params.permit(color: [:hue])).not_to have_key(:color)
    expect(params.permit(:color).to_h['color']).to equal(params[:color])
  end

  it 'loads without ActionController and registers the value once after Base and API load' do
    script = <<~'RUBY'
      require "pg_composite"
      abort "ActionController loaded eagerly" if defined?(ActionController)
      require "action_controller"
      ActionController::API
      ActionController::Base
      values = ActionController::Parameters::PERMITTED_SCALAR_TYPES
      abort "wrong registration count" unless values.count { |value| value == PgComposite::Value } == 1
      puts "ok"
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', script, chdir: File.expand_path('..', __dir__))
    expect(status).to be_success, output
    expect(output).to include('ok')
  end

  it 'registers the value once when ActionController loads before the gem' do
    script = <<~'RUBY'
      require "action_controller"
      ActionController::Base
      require "pg_composite"
      unless ActionController::Parameters.new(color: PgComposite::Value.new).permit(:color).key?(:color)
        abort "Already loaded controller was not registered"
      end
      ActionController::API
      values = ActionController::Parameters::PERMITTED_SCALAR_TYPES
      abort "wrong registration count" unless values.count { |value| value == PgComposite::Value } == 1
      puts "ok"
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, '-Ilib', '-e', script, chdir: File.expand_path('..', __dir__))
    expect(status).to be_success, output
    expect(output).to include('ok')
  end
end
