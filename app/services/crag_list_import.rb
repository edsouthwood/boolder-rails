# Reads a pasted crag list (boulder names, each followed by its problems and grades), works
# out what importing it into an area would change, and applies it.
#
# The expected text is tab-separated, as copied from a crag page:
#
#       Photo Arête            <- optional list of boulder names (space-indented)
#       Little Roof
#   \t\tName\tGrade\t...       <- header row
#   Photo Arête                <- a boulder name on its own line
#   Afternoon                  <- a note under it (not a listed name): ignored
#   \t\tPhoto Wall\tf4\t...    <- tab-led problem rows: name, then grade
#
# Only boulder names, problem names and grades are read; any other columns are ignored.
class CragListImport
  Row = Data.define(:key, :name, :grade, :raw_grade, :line)
  Section = Data.define(:name, :rows)
  Skipped = Data.define(:line, :text, :reason)
  Parsed = Data.define(:sections, :skipped)

  # What applying would do with one row:
  #   :match          an existing problem with the same name; it's put on this boulder
  #   :new            no such problem yet; created if ticked
  #   :possible_match no exact match but similar names exist; nothing happens unless chosen
  RowPlan = Struct.new(:row, :action, :problem, :similar, keyword_init: true) do
    def grade_differs?
      action == :match && problem.grade.to_s.downcase != row.grade
    end
  end
  # boulder is nil when the name is new to the area (it will be created, without an outline).
  # adopt: boulder is an unnamed outline that this list's problems already sit on; it gets the name.
  BoulderPlan = Struct.new(:name, :boulder, :rows, :adopt, keyword_init: true) do
    def moved_from(row_plan)
      current = row_plan.problem&.boulder
      current if current && current.id != boulder&.id
    end
  end

  def self.parse(text)
    text = text.to_s
    text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
    lines = text.scrub.gsub("\r\n", "\n").split("\n")
    header_index = lines.index { |line| header?(line) }
    listed = listed_names(lines, header_index)
    body = header_index ? lines.each_with_index.drop(header_index + 1) : lines.each_with_index.to_a

    sections = []
    skipped = []
    body.each do |line, index|
      number = index + 1
      next if line.strip.empty?

      if line.start_with?("\t")
        cells = line.split("\t").map(&:strip).reject(&:empty?)
        name, raw_grade = cells[0], cells[1]
        if sections.empty?
          skipped << Skipped.new(line: number, text: line.strip, reason: "problem before any boulder name")
        elsif name.blank?
          skipped << Skipped.new(line: number, text: line.strip, reason: "no problem name")
        elsif (grade = convert_grade(raw_grade))
          section = sections.last
          section.rows << Row.new(key: "line-#{number}", name: name.squish,
            grade: grade, raw_grade: raw_grade, line: number)
        else
          skipped << Skipped.new(line: number, text: name, reason: "grade \"#{raw_grade}\" isn't a bouldering grade")
        end
      else
        text = line.squish
        if listed.any? ? listed.include?(normalize(text)) : !(sections.last && sections.last.rows.empty?)
          existing = sections.find { |section| normalize(section.name) == normalize(text) }
          # A name that appears twice carries on the same boulder
          existing ? sections.push(sections.delete(existing)) : sections << Section.new(name: text, rows: [])
        else
          skipped << Skipped.new(line: number, text: text, reason: "note under #{sections.last&.name || "the list"}, ignored")
        end
      end
    end
    Parsed.new(sections: sections, skipped: skipped)
  end

  # "f6B" → "6b", "f6C+" → "6c+", "f4+" → "4+", "5" → "5". nil for anything else.
  def self.convert_grade(raw)
    match = raw.to_s.strip.downcase.delete_prefix("f").strip.match(/\A(\d)([abc])?(\+)?\z/)
    return unless match

    grade = match.captures.join
    grade if Problem::GRADE_VALUES.include?(grade)
  end

  # For comparing names: accents, case, apostrophes and punctuation ignored
  def self.normalize(name)
    name.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.
      gsub(/['’‘`´]/, "").gsub(/[^a-z0-9]+/, " ").squish
  end

  def self.header?(line)
    cells = line.split("\t").map { |cell| cell.strip.downcase }
    line.include?("\t") && cells.include?("name") && cells.include?("grade")
  end

  # Names listed before the header row (or, without one, the indented lines at the top)
  def self.listed_names(lines, header_index)
    top = header_index ? lines.first(header_index) : lines.take_while { |line| line.strip.empty? || line.match?(/\A {2,}\S/) }
    top.map(&:squish).reject(&:empty?).map { |name| normalize(name) }.to_set
  end
  private_class_method :header?, :listed_names

  attr_reader :area, :parsed

  def initialize(area, text)
    @area = area
    @parsed = self.class.parse(text)
  end

  def preview
    @preview ||= begin
      problems = area.problems.includes(:boulder).to_a
      by_name = problems.group_by { |problem| self.class.normalize(problem.name) }
      boulders = area.boulders.where.not(name: nil).index_by { |boulder| self.class.normalize(boulder.name) }
      claimed = Set.new
      adopted = Set.new

      parsed.sections.map do |section|
        rows = section.rows.map do |row|
          normalized = self.class.normalize(row.name)
          candidates = (by_name[normalized] || []).reject { |problem| claimed.include?(problem.id) }
          candidates = candidates.select { |problem| problem.grade.to_s.downcase == row.grade }.presence || candidates

          if candidates.one?
            claimed << candidates.first.id
            RowPlan.new(row: row, action: :match, problem: candidates.first, similar: [])
          else
            similar = candidates.presence || problems.reject { |problem| claimed.include?(problem.id) }.select do |problem|
              Levenshtein.distance(self.class.normalize(problem.name), normalized).between?(1, 2)
            end
            RowPlan.new(row: row, action: similar.any? ? :possible_match : :new, problem: nil, similar: similar)
          end
        end
        boulder = boulders[self.class.normalize(section.name)]
        outline = boulder ? nil : adoptable_outline(rows, adopted)
        adopted << outline.id if outline
        BoulderPlan.new(name: section.name, boulder: boulder || outline, rows: rows, adopt: outline.present?)
      end
    end
  end

  # choices: { row key => "new" | "skip" | "problem:<id>" } for :new and :possible_match rows
  #   (:new rows default to "new", :possible_match rows to "skip")
  # update_grades: ids of matched problems whose grade should become the list's
  def apply!(choices: {}, update_grades: [])
    choices = choices.to_h.transform_keys(&:to_s)
    update_grades = update_grades.map(&:to_i).to_set
    summary = Hash.new(0)

    Boulder.transaction do
      preview.each do |plan|
        boulder = plan.boulder || area.boulders.create!(name: plan.name).tap { summary[:boulders_created] += 1 }
        if plan.adopt
          boulder.update!(name: plan.name)
          summary[:outlines_named] += 1
        end

        plan.rows.each do |row_plan|
          problem = problem_for(row_plan, choices[row_plan.row.key], boulder, summary)
          next unless problem

          if problem.boulder_id != boulder.id
            summary[problem.boulder_id ? :moved : :assigned] += 1
            problem.boulder = boulder
          end
          if row_plan.grade_differs? && update_grades.include?(problem.id)
            problem.grade = row_plan.row.grade
            summary[:grades_updated] += 1
          end
          problem.save! if problem.changed?
        end
      end
    end
    summary
  end

  private

  # The unnamed outline most of these matched problems already sit on, if any (each outline
  # is only given one name per import)
  def adoptable_outline(rows, adopted)
    rows.filter_map { |row_plan| row_plan.problem&.boulder }.
      select { |boulder| boulder.placed? && boulder.name.nil? && !adopted.include?(boulder.id) }.
      tally.max_by { |_boulder, count| count }&.first
  end

  def problem_for(row_plan, choice, boulder, summary)
    case row_plan.action
    when :match
      row_plan.problem
    when :new, :possible_match
      choice ||= row_plan.action == :new ? "new" : "skip"
      if choice == "new"
        summary[:problems_created] += 1
        area.problems.create!(name: row_plan.row.name, grade: row_plan.row.grade, steepness: "other", boulder: boulder)
      elsif (id = choice[/\Aproblem:(\d+)\z/, 1]) && (chosen = row_plan.similar.find { |problem| problem.id == id.to_i })
        chosen
      else
        summary[:skipped] += 1
        nil
      end
    end
  end
end
