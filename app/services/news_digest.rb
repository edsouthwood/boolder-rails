# What's new on the public site since a date, and who to thank for it: the raw material for a
# social media post (see the bowda-news Claude skill and `bin/rails news:digest`). Read-only.
#
# Credit is whoever added the thing: a visitor (the name they typed on a contribution, photo or
# crag suggestion) or an admin (the login name on the record's "create" audit). Records made by
# scripts have no audit user, so their credit is nil.
class NewsDigest
  HIGHLIGHTS = 8

  attr_reader :since

  def initialize(since: 7.days.ago)
    @since = since
  end

  def call
    {
      since: since.iso8601,
      until: Time.current.iso8601,
      counts: { problems: new_problems.size, areas: new_areas.size, lines: new_lines.size, photos: new_topos.size },
      areas: new_areas.map { |area| area_entry(area) },
      problems: highlights.map { |problem| problem_entry(problem) },
      featured_topo: featured_topo && topo_entry(featured_topo)
    }
  end

  # Areas made public in the period: published on creation, or switched to published since
  def new_areas
    @new_areas ||= begin
      ids = Audited::Audit.where(auditable_type: "Area").where("created_at >= ?", since).select do |audit|
        published = audit.audited_changes["published"]
        audit.action == "create" ? published == true : published.is_a?(Array) && published.last == true
      end.map(&:auditable_id)
      Area.published.where(id: ids.uniq).order(:name).to_a
    end
  end

  # Problems the public can see now that were added in the period, or that became public
  # because their area was published in it
  def new_problems
    @new_problems ||= Problem.with_unpublished(false).includes(:area)
      .where("problems.created_at >= ?", since).or(Problem.with_unpublished(false).where(area_id: new_areas.map(&:id)))
      .to_a
  end

  # Lines drawn in the period on photos the public can see, on problems the public can see
  def new_lines
    @new_lines ||= Line.unscoped.with_coordinates.published.includes(:topo, problem: :area)
      .where("lines.created_at >= ?", since)
      .where(problem_id: Problem.with_unpublished(false).select(:id))
      .to_a
  end

  def new_topos
    @new_topos ||= Topo.published.where("created_at >= ?", since).select(&:publicly_visible?)
  end

  # The most interesting new problems first: ones with a line drawn, then hardest grade
  def highlights
    new_problems.sort_by { |p| [ p.has_line ? 0 : 1, -Problem.grade_rank(p.grade).to_f, p.name.to_s ] }.first(HIGHLIGHTS)
  end

  # The public photo with the most new lines on it; ties go to the newest line
  def featured_topo
    return @featured_topo if defined?(@featured_topo)

    candidates = new_lines.group_by(&:topo).select { |topo, _| topo.publicly_visible? }
    @featured_topo = candidates.max_by { |_topo, lines| [ lines.size, lines.map(&:created_at).max ] }&.first
  end

  # The first accepted contribution for the problem: usually the one it was made from, but a
  # report on a problem an admin added could win instead
  def credit_for_problem(problem)
    contribution = Contribution.where(problem_id: problem.id, state: "accepted").order(:created_at).first
    visitor(contribution&.contributor_name, "contribution") || admin_who_created(problem)
  end

  def credit_for_topo(topo)
    photo = PhotoContribution.where(topo_id: topo.id).first
    drawn = Contribution.where(id: Line.unscoped.where(topo_id: topo.id).select(:reference_contribution_id)).first
    visitor(photo&.contributor_name, "photo") || visitor(drawn&.contributor_name, "contribution") || admin_who_created(topo)
  end

  def credit_for_area(area)
    suggestion = CragSuggestion.where(area_id: area.id).first
    visitor(suggestion&.contributor_name, "crag suggestion") || admin_who_created(area)
  end

  # Starts of lines, numbered left to right, as the post's image draws them
  def self.numbered_lines(lines)
    lines.sort_by { |line| line.coordinates.first["x"].to_f }.each_with_index.map { |line, i| [ i + 1, line ] }
  end

  private

  def visitor(name, source)
    name = name.to_s.squish
    { kind: "visitor", name: name, source: source } if name.present?
  end

  def admin_who_created(record)
    username = Audited::Audit.where(auditable: record, action: "create").pick(:username)
    { kind: "admin", name: username, source: "admin" } if username.present?
  end

  # Always the public address, even when run on a copy of the data
  def url(path) = "https://#{ENV.fetch("APP_HOST", "bowda.rocks")}#{path}"

  def problem_entry(problem)
    {
      id: problem.id, name: problem.name_with_fallback, grade: problem.grade, area: problem.area.name,
      has_line: problem.has_line, url: url("/p/#{problem.id}"), credit: credit_for_problem(problem)
    }
  end

  def area_entry(area)
    {
      id: area.id, name: area.name, problems: area.problems.with_unpublished(false).count,
      url: url(Rails.application.routes.url_helpers.area_path(slug: area.slug)), credit: credit_for_area(area)
    }
  end

  def topo_entry(topo)
    lines = Line.where(topo: topo).with_coordinates.includes(problem: :area)
      .where(problem_id: Problem.with_unpublished(false).select(:id))
    {
      id: topo.id, area: topo.problems.first&.area&.name, photo_url: url("/proxy/topos/#{topo.id}"),
      credit: credit_for_topo(topo),
      lines: self.class.numbered_lines(lines).map do |number, line|
        { number: number, problem: line.problem.name_with_fallback, grade: line.problem.grade, url: url("/p/#{line.problem_id}") }
      end
    }
  end
end
