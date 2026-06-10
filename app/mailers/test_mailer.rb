class TestMailer < ApplicationMailer
  def test_email
    mail(to: ContributeMailer.notification_recipients, subject: "Test")
  end
end
