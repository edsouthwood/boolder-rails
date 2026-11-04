# Numbers for the admin Stats page: anonymous visit totals (PageView), mapping progress
# per area, and community and admin activity, all from data the site already keeps.
class AdminStats
  PERIODS = [ 7, 30, 90, 365 ].freeze
  WEEKS = 12

  attr_reader :days

  def initialize(days: 30)
    @days = PERIODS.include?(days.to_i) ? days.to_i : 30
  end

  # ─── Visits ────────────────────────────────────────────────────────────────

  def range = (Date.current - (days - 1))..Date.current
  def previous_range = (range.first - days)..(range.first - 1)

  def counting_since = @counting_since ||= PageView.minimum(:day)

  def total_views = @total_views ||= PageView.between(range).sum(:views)
  def previous_views = @previous_views ||= PageView.between(previous_range).sum(:views)

  # Only meaningful when counting covers the whole previous period
  def change_percent
    return if counting_since.nil? || counting_since > previous_range.first || previous_views.zero?

    ((total_views - previous_views) * 100.0 / previous_views).round
  end

  def views_by_kind = @views_by_kind ||= PageView.between(range).group(:kind).sum(:views)

  # [[day, views]] for every day in the period, zeros included
  def daily_views
    counts = PageView.between(range).group(:day).sum(:views)
    range.map { |day| [ day, counts[day].to_i ] }
  end

  # Areas by views of the area page, its problems and its map: [[area, {kind => n}, total]]
  def top_areas(limit = 10)
    by = Hash.new { |h, k| h[k] = Hash.new(0) }
    PageView.between(range).where.not(area_id: 0).group(:area_id, :kind).sum(:views).each { |(area_id, kind), n| by[area_id][kind] += n }
    areas = Area.where(id: by.keys).index_by(&:id)
    by.filter_map { |id, kinds| areas[id] && [ areas[id], kinds, kinds.values.sum ] }.max_by(limit) { |_, _, total| total }
  end

  # [[problem, views]]
  def top_problems(limit = 15)
    counts = PageView.between(range).where.not(problem_id: 0).group(:problem_id).sum(:views).max_by(limit) { |_, n| n }
    problems = Problem.where(id: counts.map(&:first)).includes(:area).index_by(&:id)
    counts.filter_map { |id, n| problems[id] && [ problems[id], n ] }
  end

  # ─── Mapping progress ────────────────────────────────────────────────────

  Progress = Struct.new(:area, :problems, :placed, :estimated, :unlocated, :with_line, :photos, :to_draw, :boulders_on_map, :boulders, keyword_init: true) do
    def line_percent = problems.zero? ? 0 : (with_line * 100.0 / problems).round
    def placed_percent = problems.zero? ? 0 : (placed * 100.0 / problems).round
  end

  def progress
    @progress ||= Area.order(:name).map do |area|
      shown = area.problems.shown
      located = shown.where.not(location: nil)
      Progress.new(
        area: area,
        problems: shown.count,
        placed: located.where(location_estimated: false).count,
        estimated: located.where(location_estimated: true).count,
        unlocated: shown.where(location: nil).count,
        with_line: shown.where(has_line: true).count,
        photos: Topo.in_area(area).count,
        to_draw: Topo.in_area(area).undrawn.count,
        boulders_on_map: area.boulders.placed.count,
        boulders: area.boulders.count
      )
    end
  end

  def progress_totals
    keys = %i[problems placed estimated unlocated with_line photos to_draw boulders_on_map boulders]
    Progress.new(**keys.to_h { |key| [ key, progress.sum(&key) ] })
  end

  # ─── Weekly activity ─────────────────────────────────────────────────────

  def week_starts
    @week_starts ||= (0...WEEKS).map { |i| Date.current.beginning_of_week - (WEEKS - 1 - i).weeks }
  end

  # {label => [count per week]} for things added each week
  def weekly
    @weekly ||= {
      "Problems added" => per_week(Problem.all),
      "Lines drawn" => per_week(Line.where.not(coordinates: nil)),
      "Photos added" => per_week(Topo.all),
      "Contributions and reports" => per_week(Contribution.all),
      "Photos from visitors" => per_week(PhotoContribution.all),
      "Admin edits" => per_week(Audited::Audit.all)
    }
  end

  # ─── Community ───────────────────────────────────────────────────────────

  def contribution_states = Contribution.group(:state).count
  def photo_contribution_states = PhotoContribution.group(:state).count

  # Median days from sending to a decision, over the last 90 days' decisions
  def contribution_review_days
    median_days(Contribution.where("coalesce(accepted_at, closed_at) > ?", 90.days.ago).
      pluck(:created_at, Arel.sql("coalesce(accepted_at, closed_at)")))
  end

  def photo_review_days
    median_days(PhotoContribution.where("reviewed_at > ?", 90.days.ago).pluck(:created_at, :reviewed_at))
  end

  # ─── Admin activity ──────────────────────────────────────────────────────

  # [[username, {type => count}, total]] for the last 30 days
  def admin_activity
    by = Hash.new { |h, k| h[k] = Hash.new(0) }
    Audited::Audit.where("created_at > ?", 30.days.ago).group(:username, :auditable_type).count.
      each { |(user, type), n| by[user.presence || "site and background jobs"][type] += n }
    by.map { |user, types| [ user, types, types.values.sum ] }.sort_by { |_, _, total| -total }
  end

  private

  def per_week(scope)
    counts = scope.reorder(nil).where(created_at: week_starts.first.beginning_of_day..).
      group(Arel.sql("date_trunc('week', created_at AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/London')::date")).count
    week_starts.map { |week| counts[week].to_i }
  end

  def median_days(pairs)
    days = pairs.filter_map { |from, to| (to - from) / 1.day if from && to }.sort
    return if days.empty?

    mid = days.size / 2
    (days.size.odd? ? days[mid] : (days[mid - 1] + days[mid]) / 2).round(1)
  end
end
