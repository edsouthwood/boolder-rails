# A 1080x1350 (Instagram portrait) JPEG for a NewsDigest post: the featured photo with its
# lines drawn as the website draws them, numbered left to right, over a footer with the week's
# numbers and the photo credit.
class NewsDigest::Image
  include TopoSheetHelper

  WIDTH = 1080
  HEIGHT = 1350
  PHOTO_HEIGHT = 1110
  FOOTER_HEIGHT = HEIGHT - PHOTO_HEIGHT
  GRANITE = "#33393D".freeze
  STONE = "#F4F3F1".freeze
  FONT = "DejaVu Sans".freeze

  # topo: the photo to feature; headline: e.g. "12 new problems · 1 new crag";
  # credit: who to thank for the photo, as it should read
  def initialize(topo:, headline:, credit:)
    @topo = topo
    @headline = headline
    @credit = credit
  end


  def write(path)
    image.write_to_file(path.to_s, Q: 90, strip: true)
    path
  end

  def image
    photo_part.join(footer, :vertical)
  end

  # Our own SVG (config/initializers/vips.rb blocks the SVG loader for uploads). Names in it
  # are XML-escaped; the loader is blocked again straight after, so uploads never reach it.
  def self.svg(source)
    Vips.block("VipsForeignLoadSvg", false)
    Vips::Image.svgload_buffer(source).copy_memory
  ensure
    Vips.block_untrusted(true)
  end

  private

  attr_reader :topo, :headline, :credit

  # The photo's crag, top right of the footer
  def place
    Area.find_by(id: topo.area_id)&.name
  end

  def lines
    @lines ||= Line.where(topo: topo).with_coordinates.includes(:problem)
      .where(problem_id: Problem.with_unpublished(false).select(:id)).to_a
      .select { |line| line.coordinates.size >= 2 }
  end

  # From the original upload, cut as display_photo is (older topos are a centre 4:3 crop, which
  # their lines are fractions of), so nothing is written to storage
  def photo
    @photo ||= begin
      image = flat(Vips::Image.new_from_buffer(topo.photo.download, "").autorot)
      if topo.uncropped?
        image
      else
        scale = [ 1200.0 / image.width, 900.0 / image.height ].max
        scaled = image.resize(scale)
        scaled.crop(((scaled.width - 1200) / 2).clamp(0, scaled.width), ((scaled.height - 900) / 2).clamp(0, scaled.height),
                    [ 1200, scaled.width ].min, [ 900, scaled.height ].min)
      end
    end
  end

  # The photo scaled to cover the space, lines drawn on, then cropped around the lines
  def photo_part
    scale = [ WIDTH.to_f / photo.width, PHOTO_HEIGHT.to_f / photo.height ].max
    scaled = photo.resize(scale)
    drawn = flat(scaled.composite(self.class.svg(lines_svg(scaled.width, scaled.height)), :over))

    left, top = crop_origin(scaled.width, scaled.height)
    drawn.crop(left, top, WIDTH, PHOTO_HEIGHT)
  end

  # Centred on the middle of the lines, kept inside the photo
  def crop_origin(width, height)
    points = lines.flat_map(&:coordinates)
    cx = points.any? ? points.sum { |p| p["x"].to_f } / points.size * width : width / 2.0
    cy = points.any? ? points.sum { |p| p["y"].to_f } / points.size * height : height / 2.0
    [ (cx - WIDTH / 2.0).round.clamp(0, width - WIDTH), (cy - PHOTO_HEIGHT / 2.0).round.clamp(0, height - PHOTO_HEIGHT) ]
  end

  # The print sheet's drawing (areas/print.html.erb) on a 400-wide viewBox, stretched over the photo
  def lines_svg(width, height)
    h = (400.0 * height / width).round(1)
    paths = lines.map do |line|
      d = topo_line_path(line.coordinates, h)
      color = helpers.grade_color(line.problem.grade)
      %(<path d="#{d}" fill="none" stroke="#000" stroke-opacity="0.45" stroke-width="5" stroke-linecap="round"/>) +
        %(<path d="#{d}" fill="none" stroke="#{color}" stroke-width="3" stroke-linecap="round"/>)
    end
    dots = NewsDigest.numbered_lines(lines).map do |number, line|
      x, y = topo_line_start(line.coordinates, h)
      grade = line.problem.grade
      %(<circle cx="#{x}" cy="#{y}" r="10" fill="#{helpers.grade_color(grade)}" stroke="#000" stroke-opacity="0.6" stroke-width="1.5"/>) +
        %(<text x="#{x}" y="#{y}" dy="4" text-anchor="middle" font-size="12" font-weight="700" font-family="#{FONT}" fill="#{helpers.grade_text_color(grade)}">#{number}</text>)
    end
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 400 #{h}">
        #{paths.join}#{dots.join}
      </svg>
    SVG
  end

  def footer
    flat(self.class.svg(footer_svg))
  end

  def footer_svg
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{FOOTER_HEIGHT}" viewBox="0 0 #{WIDTH} #{FOOTER_HEIGHT}">
        <rect width="#{WIDTH}" height="#{FOOTER_HEIGHT}" fill="#{STONE}"/>
        <rect width="#{WIDTH}" height="8" fill="#{GRANITE}"/>
        #{wordmark(x: 56, y: 36, height: 84)}
        <text x="#{WIDTH - 56}" y="86" text-anchor="end" font-family="#{FONT}" font-size="30" font-weight="700" fill="#{GRANITE}">#{escape(place)}</text>
        <text x="56" y="172" font-family="#{FONT}" font-size="40" font-weight="700" fill="#{GRANITE}">#{escape(headline)}</text>
        <text x="56" y="214" font-family="#{FONT}" font-size="26" fill="#6F767A">#{escape("Photo: #{credit} · bowda.rocks")}</text>
      </svg>
    SVG
  end

  # The site's header logo, nested at the given place
  def wordmark(x:, y:, height:)
    svg = Rails.root.join("app/assets/images/bowda-header.svg").read.sub(/\A<\?xml[^>]*>\s*/, "")
    width = (height * 286.6 / 74.1).round
    svg.sub(/<svg\b[^>]*?\swidth="[^"]*"\s+height="[^"]*"/) { |tag| tag.sub(/\swidth="[^"]*"\s+height="[^"]*"/, %( x="#{x}" y="#{y}" width="#{width}" height="#{height}")) }
  end

  def escape(text) = ERB::Util.html_escape(text.to_s)

  def helpers = ApplicationController.helpers

  # sRGB, three bands, no alpha
  def flat(image)
    image = image.colourspace(:srgb) unless image.interpretation == :srgb
    image = image.flatten(background: [ 255, 255, 255 ]) if image.has_alpha?
    image.bands > 3 ? image.extract_band(0, n: 3) : image
  end
end
