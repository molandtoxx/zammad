class SecureMailing::SMIME::Outgoing < SecureMailing::Backend::Handler

  def initialize(mail, security)
    @mail     = mail
    @security = security
  end

  def process
    return if !process?

    if @security[:sign][:success] && @security[:encryption][:success]
      processed = encrypt(signed)
      log('sign', 'success')
      log('encryption', 'success')
    elsif @security[:sign][:success]
      processed = Mail.new(signed)
      log('sign', 'success')
    elsif @security[:encryption][:success]
      processed = encrypt(@mail.encoded)
      log('encryption', 'success')
    end

    overwrite_mail(processed)
  end

  def process?
    return false if @security.blank?
    return false if @security[:type] != 'S/MIME'

    @security[:sign][:success] || @security[:encryption][:success]
  end

  def overwrite_mail(processed)
    @mail.body = nil
    @mail.body = processed.body.encoded

    @mail.content_disposition       = processed.content_disposition
    @mail.content_transfer_encoding = processed.content_transfer_encoding
    @mail.content_type              = processed.content_type
  end

  def signed
    from       = @mail.from.first
    cert_model = SMIMECertificate.for_sender_email_address(from)
    raise "Unable to find ssl private key for '#{from}'" if !cert_model
    raise "Expired certificate for #{from} (fingerprint #{cert_model.fingerprint}) with #{cert_model.not_before_at} to #{cert_model.not_after_at}" if !@security[:sign][:allow_expired] && cert_model.expired?

    private_key = OpenSSL::PKey::RSA.new(cert_model.private_key, cert_model.private_key_secret)
    OpenSSL::PKCS7.write_smime(OpenSSL::PKCS7.sign(cert_model.parsed, private_key, @mail.encoded, [], OpenSSL::PKCS7::DETACHED))
  rescue => e
    log('sign', 'failed', e.message)
    raise
  end

  def encrypt(data)
    certificates = SMIMECertificate.for_recipipent_email_addresses!(@mail.to)
    expired_cert = certificates.detect(&:expired?)
    raise "Expired certificates for cert with #{expired_cert.not_before_at} to #{expired_cert.not_after_at}" if !@security[:encryption][:allow_expired] && expired_cert.present?

    Mail.new(OpenSSL::PKCS7.write_smime(OpenSSL::PKCS7.encrypt(certificates.map(&:parsed), data, cipher)))
  rescue => e
    log('encryption', 'failed', e.message)
    raise
  end

  def cipher
    @cipher ||= OpenSSL::Cipher.new('AES-128-CBC')
  end

  def log(action, status, error = nil)
    HttpLog.create(
      direction:     'out',
      facility:      'S/MIME',
      url:           "#{@mail[:from]} -> #{@mail[:to]}",
      status:        status,
      ip:            nil,
      request:       @security,
      response:      { error: error },
      method:        action,
      created_by_id: 1,
      updated_by_id: 1,
    )
  end
end
