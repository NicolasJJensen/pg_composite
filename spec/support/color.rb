module ExampleColors
  class OklchColor < PgComposite::Value
    self.sql_type = "oklch_color"
    member :lightness, default: 0.0
    member :chroma, column: :color, default: 0.0
    member :hue, default: 0.0
    member :alpha, default: 1.0
  end

  class OklchColorType < PgComposite::Type
    self.subtype = OklchColor
  end
end
