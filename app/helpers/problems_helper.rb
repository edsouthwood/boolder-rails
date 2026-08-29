module ProblemsHelper
  # Canonical grade -> colour mapping for the whole site. The problem lists, the
  # topo circles, the search results and the map all colour by grade, and all of
  # them read from here (the JS controllers get it via `grade_colors_json`), so
  # there is one place to change a colour.
  GRADE_COLORS = [
    [ "#FF9500", %w[1 1+ 2 2+ 3 3+ 4 4+ 4a 4a+ 4b 4b+ 4c 4c+] ],
    [ "#017AFF", %w[5 5+ 5a 5a+ 5b 5b+ 5c 5c+ 6a 6a+] ],
    [ "#FF3B2F", %w[6b 6b+ 6c] ],
    [ "#FFFFFF", %w[6c+ 7a 7a+ 7b] ],
    [ "#000000", %w[7b+ 7c 7c+ 8a 8a+ 8b 8b+ 8c 8c+ 9a 9a+ 9b 9b+ 9c 9c+] ]
  ].freeze

  # Ungraded / unrecognised grades.
  UNKNOWN_GRADE_COLOR = "#878A8D".freeze

  # Pale swatches need an outline to stay visible on a white page.
  GRADE_OUTLINE_COLOR = "#888".freeze

  def problem_circle_view(problem, klass: "h-6 w-6 leading-6")
    grade_circle_view(problem.grade,
      content: problem.circuit_number_simplified || "&nbsp;".html_safe,
      klass: klass
    )
  end

  # A grade-coloured dot. Used for problem lists, topo markers and anywhere else a
  # problem is represented by a circle.
  def grade_circle_view(grade, content: "&nbsp;".html_safe, klass: "h-6 w-6 leading-6")
    circle_view(content,
      background_color: grade_color(grade),
      text_color: grade_text_color(grade),
      border_color: grade_outline_color(grade),
      klass: klass
    )
  end

  def problem_circle_view_with_name(problem)
    problem_circle_view(problem) +
      (link_to problem.name_with_fallback, admin_problem_path(problem), class: "ml-2")
  end

  def circuit_circle_view(circuit, klass: "h-6 w-6 leading-6")
    circle_view("&nbsp;".html_safe,
      background_color: uicolor(circuit&.color),
      text_color: text_color(circuit&.color),
      klass: klass
    )
  end

  def uicolor(circuit_color, fallback: "rgb(80% 80% 80%)")
    color_mapping[circuit_color] || fallback
  end

  def grade_color(grade)
    key = grade.to_s.strip.downcase
    match = GRADE_COLORS.find { |_color, grades| grades.include?(key) }
    match ? match.first : UNKNOWN_GRADE_COLOR
  end

  # White dots would vanish against the page, so they get an outline — the same
  # treatment the map gives them via circle-stroke-color.
  def grade_outline_color(grade)
    GRADE_OUTLINE_COLOR if grade_color(grade) == "#FFFFFF"
  end

  def grade_text_color(grade)
    grade_color(grade) == "#FFFFFF" ? "#333" : "#FFF"
  end

  # The mapping in the form the Stimulus controllers want: an ordered list of
  # [color, [grades]] pairs plus the fallback colour for anything unmatched.
  def grade_colors_json
    { colors: GRADE_COLORS, unknown: UNKNOWN_GRADE_COLOR, outline: GRADE_OUTLINE_COLOR }.to_json
  end

  def bleau_info_url(problem)
    "https://bleau.info/c/#{problem.bleau_info_id}.html" if problem.bleau_info_id.present?
  end

  def problem_friendly_path(problem)
    area_problem_path(problem.area, problem)
  end

  def circle_view(content, background_color: "", text_color: "", border_color: nil, klass: "h-6 w-6 leading-6")
    style = "background-color: #{background_color}; color: #{text_color}"
    # inset shadow rather than a border: it outlines the dot without changing its size.
    style += "; box-shadow: inset 0 0 0 1px #{border_color}" if border_color.present?

    content_tag(:span, content, style: style,
      class: "rounded-full #{klass} inline-flex justify-center")
  end

  private

  # Circuit colours (not grade colours — those live in GRADE_COLORS above and are
  # shared with the JS controllers through `grade_colors_json`). search_controller.js
  # still carries its own copy of this circuit mapping.
  def color_mapping
     {
      yellow:   "#FFCC02",
      purple:   "#D783FF",
      orange:   "#FF9500",
      green:    "#77C344",
      blue:     "#017AFF",
      skyblue:  "#5AC7FA",
      salmon:   "#FDAF8A",
      red:      "#FF3B2F",
      black:    "#000000",
      white:    "#FFFFFF"
    }.with_indifferent_access
  end

  def text_color(circuit_color)
    if circuit_color.to_s == "white"
      "#333"
    else
      "#FFF"
    end
  end
end
