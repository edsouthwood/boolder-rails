require "test_helper"

class ContributeMailerTest < ActionMailer::TestCase
  test "staff notification falls back to the Dartmoor team" do
    ENV.delete("CONTRIBUTION_EMAILS")
    assert_includes ContributeMailer.notification_recipients, "bowda@edsouthwood.com"
  end

  test "CONTRIBUTION_EMAILS env overrides recipients (comma-separated)" do
    ENV["CONTRIBUTION_EMAILS"] = "a@x.com, b@y.com"
    assert_equal [ "a@x.com", "b@y.com" ], ContributeMailer.notification_recipients
  ensure
    ENV.delete("CONTRIBUTION_EMAILS")
  end

  test "staff notification is addressed to the configured recipients" do
    contribution = Contribution.create!(state: "pending", comment: "x", problem_name: "Slab")
    mail = ContributeMailer.with(contribution: contribution).new_contribution_email
    assert_equal ContributeMailer.notification_recipients, mail.to
  end

  test "contributor emails are addressed to the contributor" do
    contribution = Contribution.create!(state: "pending", comment: "x", contributor_name: "Ed", contributor_email: "ed@example.com", problem_name: "Slab")

    %i[acknowledgement_email accepted_email declined_email].each do |action|
      mail = ContributeMailer.with(contribution: contribution).public_send(action)
      assert_equal [ "ed@example.com" ], mail.to, "#{action} should go to the contributor"
    end
  end

  test "declined email includes the moderator note" do
    contribution = Contribution.create!(state: "closed", comment: "x", contributor_email: "ed@example.com",
                                        problem_name: "Slab", moderator_note: "Duplicate of an existing problem")
    mail = ContributeMailer.with(contribution: contribution).declined_email
    assert_match "Duplicate of an existing problem", mail.body.encoded
  end

  test "no contributor email is sent when the address is blank" do
    contribution = Contribution.create!(state: "accepted", comment: "x")

    assert_no_emails do
      ContributeMailer.with(contribution: contribution).acknowledgement_email.deliver_now
    end
  end
end
