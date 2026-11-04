module Admin::StatsHelper
  GRANITE = "#33393D".freeze
  GRID = "rgba(51, 57, 61, 0.08)".freeze

  # A single-series Chart.js chart (granite, no legend: the heading names it) for the
  # `chart` Stimulus controller. Hover tooltips are Chart.js's defaults.
  def stats_chart(type:, labels:, values:, label:, height: 180)
    dataset = { label: label, data: values, backgroundColor: GRANITE, borderColor: GRANITE }
    dataset.merge!(type == "bar" ? { borderRadius: 4, maxBarThickness: 28 } : { borderWidth: 2, pointRadius: 0, pointHoverRadius: 4, tension: 0.2, fill: false })
    options = {
      maintainAspectRatio: false,
      interaction: { mode: "index", intersect: false },
      plugins: { legend: { display: false } },
      scales: {
        x: { grid: { display: false }, ticks: { maxTicksLimit: type == "bar" ? 4 : 8, maxRotation: 0, color: "#6b7280" } },
        y: { beginAtZero: true, grid: { color: GRID }, border: { display: false }, ticks: { precision: 0, maxTicksLimit: 5, color: "#6b7280" } }
      }
    }
    tag.div(style: "position:relative;height:#{height}px") do
      tag.canvas(role: "img", aria: { label: "#{label}: #{values.sum} in total" },
        data: { controller: "chart", chart_type_value: type, chart_data_value: { labels: labels, datasets: [ dataset ] }.to_json,
                chart_options_value: options.to_json })
    end
  end

  def stats_change(percent)
    return if percent.nil?

    color = percent.positive? ? "text-green-700" : (percent.negative? ? "text-amber-700" : "text-gray-500")
    tag.span("#{percent.positive? ? "+" : ""}#{percent}% on the previous #{pluralize(@stats.days, "day")}", class: "text-xs #{color}")
  end
end
