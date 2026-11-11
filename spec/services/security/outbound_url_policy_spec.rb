# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Security::OutboundUrlPolicy do
  describe '.validate!' do
    it 'accepts HTTPS only after every resolved address is public' do
      allow(Resolv).to receive(:getaddresses).with('api.example.com').and_return(['93.184.216.34'])

      result = described_class.validate!('https://api.example.com/hooks?mode=safe')

      expect(result.uri.to_s).to eq('https://api.example.com/hooks?mode=safe')
      expect(result.ip_address).to eq('93.184.216.34')
    end

    it 'rejects private, loopback, link-local and mixed DNS answers' do
      unsafe_answers = [
        ['10.0.0.1'],
        ['127.0.0.1'],
        ['169.254.169.254'],
        ['::1'],
        ['93.184.216.34', '192.168.1.1']
      ]

      unsafe_answers.each do |answers|
        allow(Resolv).to receive(:getaddresses).with('unsafe.example').and_return(answers)
        expect { described_class.validate!('https://unsafe.example/hook') }
          .to raise_error(ArgumentError, /non-public/)
      end
    end

    it 'rejects HTTP, embedded credentials, fragments and unresolved hosts' do
      expect { described_class.validate!('http://api.example.com/hook') }.to raise_error(ArgumentError)
      expect { described_class.validate!('https://user:pass@api.example.com/hook') }.to raise_error(ArgumentError)
      expect { described_class.validate!('https://api.example.com/hook#secret') }.to raise_error(ArgumentError)

      allow(Resolv).to receive(:getaddresses).with('missing.example').and_return([])
      expect { described_class.validate!('https://missing.example/hook') }.to raise_error(ArgumentError, /resolved/)
    end
  end
end
