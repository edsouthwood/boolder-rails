require "test_helper"

class PhotoContributionMailerTest < ActionMailer::TestCase
  setup do
    @area = Area.create!(name: "Photo Tor", slug: "photo-tor", published: true)
    @pc = PhotoContribution.new(area: @area, contributor_name: "<b>Spam</b> me", contributor_email: "ann@example.com", comment: "North face")
    @pc.photo.attach(io: StringIO.new("fake image"), filename: "boulder.jpg", content_type: "image/jpeg")
    @pc.save!
  end

  test "staff hear about new photos, with a link to the queue" do
    mail = PhotoContributionMailer.with(photo_contribution: @pc).new_photos_email
    assert_equal "New boulder photos at Photo Tor", mail.subject
    assert_match "/admin/photo-contributions", mail.body.encoded
    assert_match "North face", mail.body.encoded
  end

  test "the acknowledgement doesn't echo the contributor's own text" do
    mail = PhotoContributionMailer.with(photo_contribution: @pc).acknowledgement_email
    assert_equal [ "ann@example.com" ], mail.to
    assert_match "Photo Tor", mail.body.encoded
    assert_no_match "Spam", mail.body.encoded
    assert_no_match "North face", mail.body.encoded
  end

  test "no acknowledgement without an email" do
    @pc.update!(contributor_email: nil)
    assert_nil PhotoContributionMailer.with(photo_contribution: @pc).acknowledgement_email.message.to
  end

  test "the review email counts what was accepted or declined" do
    mail = PhotoContributionMailer.with(contributor_email: "ann@example.com", contributor_name: "Ann", accepted: 3, closed: 0).reviewed_email
    assert_match "3 of your photos have been accepted", mail.body.encoded

    mail = PhotoContributionMailer.with(contributor_email: "ann@example.com", accepted: 0, closed: 1, note: "Too dark").reviewed_email
    assert_match "one of your photos", mail.body.encoded
    assert_match "Too dark", mail.body.encoded
  end
end
