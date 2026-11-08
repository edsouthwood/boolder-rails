module ApplicationHelper
  # Structured data for search engines, built from a hash so the JSON is always valid.
  # to_json escapes <, > and & (as \u003c etc.), so a name can't close the script tag.
  # Never build JSON-LD by hand in ERB: `j` makes \' (invalid JSON) and ERB then
  # HTML-escapes quotes to &quot;, which Search Console reports as bad escapes.
  def json_ld_tag(data)
    tag.script(data.to_json.html_safe, type: "application/ld+json")
  end

  # Search engines can show this trail ("bowda.rocks › Dartmoor › Saddle Tor") in place
  # of the raw URL. Pass [name, url] pairs, top level first, ending with the page itself.
  # Every step needs a URL, so steps with no page of their own (a boulder) are left out.
  def breadcrumb_json_ld(*crumbs)
    json_ld_tag("@context": "https://schema.org", "@type": "BreadcrumbList",
                itemListElement: crumbs.each_with_index.map { |(name, url), i|
                  { "@type": "ListItem", position: i + 1, name: name, item: url }
                })
  end

  # Where the "Buy Bowda a coffee" button on /support points (e.g. a Ko-fi page): the
  # SUPPORT_URL env var, else the `support_url` credential. Nil hides the button and the
  # page shows a "donations open soon" note instead. Only http(s) addresses are used.
  def support_donation_url
    url = ENV["SUPPORT_URL"].presence || Rails.application.credentials.support_url.presence
    url if url.to_s.match?(%r{\Ahttps?://}i)
  end

  # A visitor's uploaded image as shown publicly: a resized copy with its EXIF (camera
  # details, exact GPS) stripped, never the original file.
  def public_photo(attachment)
    return attachment unless attachment.variable?

    attachment.variant(resize_to_limit: [ 1600, 1600 ], saver: { quality: 70, strip: true })
  end

  # Icons in public/ are served with a one-year cache at fixed URLs, so browsers keep
  # whatever they fetched first (the old green Boolder icon until 31 Oct 2026). Bump this
  # whenever the icon files change, so every browser fetches the new ones.
  ICON_VERSION = "2".freeze

  def site_icon_path(file)
    "/#{file}?v=#{ICON_VERSION}"
  end

  LOGO_POINTS = "40.35,112.36 21.90,30.93 36.34,18.36 71.58,34.59 72.17,64.70 94.60,82.02 98.95,112.36".freeze

  # Top-nav link classes, highlighting the section the visitor is currently in.
  def nav_link_classes(active:)
    base = "flex items-center min-h-[44px] px-3.5 rounded-lg text-[15px] "
    if active
      base + "font-semibold text-granite bg-ground"
    else
      base + "font-medium text-muted hover:text-granite hover:bg-ground"
    end
  end

  # The bowda "B" drawn inline, so it can take any colour (e.g. light on the granite footer).
  def bowda_logo_svg(color: "#6F767A", **options)
    options[:"aria-hidden"] = "true" unless options.key?(:"aria-label")
    tag.svg(xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 117 133", **options) do
      tag.polygon(points: LOGO_POINTS, fill: "none", stroke: color, "stroke-width": 11, "stroke-linejoin": "round")
    end
  end
end
