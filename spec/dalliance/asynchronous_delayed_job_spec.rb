require 'spec_helper'

RSpec.describe DallianceModel do
  subject { DallianceModel.create }

  before(:all) do
    DallianceModel.dalliance_options[:background_processing] = true
    if defined?(ActiveJob)
      ActiveJob::Base.queue_adapter = :delayed_job
    end
  end

  before do
    Delayed::Job.destroy_all
  end

  context "no worker_class" do
    before(:all) do
      DallianceModel.dalliance_options[:dalliance_method] = :dalliance_success_method
      DallianceModel.dalliance_options[:worker_class] = nil
      DallianceModel.dalliance_options[:queue] = 'dalliance'
    end

    it "should raise an error" do
      expect { subject.dalliance_background_process }.to raise_error(NoMethodError)
    end
  end

  context "success" do
    before(:all) do
      DallianceModel.dalliance_options[:dalliance_method] = :dalliance_success_method
      DallianceModel.dalliance_options[:worker_class] = Dalliance::Workers::DelayedJob
      DallianceModel.dalliance_options[:queue] = 'dalliance'
      DallianceModel.dalliance_options[:duration_column] = 'dalliance_duration'
    end

    it "should not call the dalliance_method w/o a Delayed::Worker" do
      subject.dalliance_background_process
      subject.reload

      expect(subject).not_to be_successful
      expect(Delayed::Job.count).to eq(1)
    end

    it "should call the dalliance_method w/ a Delayed::Worker" do
      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject).to be_successful
      expect(Delayed::Job.count).to eq(0)
    end

    it "should set the dalliance_status to completed" do
      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject).to be_completed
    end

    it "should set the dalliance_progress to 100" do
      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject.dalliance_progress).to eq(100)
    end

    it "should set the dalliance_duration" do
      expect(subject.dalliance_duration).to eq(nil)

      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject.dalliance_duration).not_to eq(nil)
    end

    context "another_queue" do
      let(:queue) { 'dalliance_2'}

      before do
        DallianceModel.dalliance_options[:queue] = queue
      end

      it "should NOT call the dalliance_method w/ a Delayed::Worker (different queue)" do
        subject.dalliance_background_process
        Delayed::Worker.new(:queues => [:dalliance]).work_off
        subject.reload

        expect(subject).not_to be_successful
        expect(Delayed::Job.count).to eq(1)
      end

      it "should call the dalliance_method w/ a Delayed::Worker (same queue)" do
        subject.dalliance_background_process
        Delayed::Worker.new(:queues => [queue]).work_off
        subject.reload

        expect(subject).to be_successful
        expect(Delayed::Job.count).to eq(0)
      end
    end
  end

  context "raise error" do
    before(:all) do
      DallianceModel.dalliance_options[:dalliance_method] = :dalliance_error_method
      DallianceModel.dalliance_options[:worker_class] = Dalliance::Workers::DelayedJob
      DallianceModel.dalliance_options[:queue] = 'dalliance'
    end

    it "should NOT raise an error" do
      subject.dalliance_background_process

      Delayed::Worker.new(:queues => [:dalliance]).work_off

      expect(Delayed::Job.count).to eq(0)
    end

    it "should store the error" do
      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject.dalliance_error_hash).not_to be_empty
      expect(subject.dalliance_error_hash[:error]).to eq(RuntimeError.name) #We store the class name...
      expect(subject.dalliance_error_hash[:message]).to eq('RuntimeError')
      expect(subject.dalliance_error_hash[:backtrace]).not_to be_blank
    end

    it "should set the dalliance_status to processing_error" do
      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject).to be_processing_error
    end

    it "should set the dalliance_progress to 0" do
      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject.dalliance_progress).to eq(0)
    end

    it "should handle persistance errors" do
      DallianceModel.dalliance_options[:dalliance_method] = :dalliance_error_method
      allow_any_instance_of(DallianceModel).to receive(:error_dalliance!).and_raise(RuntimeError.new)

      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject).to be_processing_error
      expect(subject.dalliance_error_hash).not_to be_empty
      expect(subject.dalliance_error_hash[:error]).to eq('Persistance Failure: See Logs')
    end

    context "error_notifier" do
      it "should pass the errors" do
        DallianceModel.dalliance_options[:error_notifier] = ->(error){ @error_report = "#{error}" }

        subject.dalliance_background_process
        Delayed::Worker.new(:queues => [:dalliance]).work_off

        expect(@error_report).to eq('RuntimeError')
      end
    end
  end

  context "validation error" do
    before(:all) do
      DallianceModel.dalliance_options[:dalliance_method] = :dalliance_validation_error_method
      DallianceModel.dalliance_options[:worker_class] = Dalliance::Workers::DelayedJob
      DallianceModel.dalliance_options[:queue] = 'dalliance'
    end

    it "should store the error" do
      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject.dalliance_error_hash).not_to be_empty
      expect(subject.dalliance_error_hash[:successful]).to eq(['is invalid'])
    end

    it "should set the dalliance_status to validation_error" do
      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject).to be_validation_error
    end

    it "should set the dalliance_progress to 0" do
      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject.dalliance_progress).to eq(0)
    end

    it "should handle persistance errors" do
      DallianceModel.dalliance_options[:dalliance_method] = :dalliance_validation_error_method
      allow_any_instance_of(DallianceModel).to receive(:validation_error_dalliance!).and_raise(RuntimeError.new)

      subject.dalliance_background_process
      Delayed::Worker.new(:queues => [:dalliance]).work_off
      subject.reload

      expect(subject).to be_validation_error
      expect(subject.dalliance_error_hash).not_to be_empty
      expect(subject.dalliance_error_hash[:error]).to eq('Persistance Failure: See Logs')
    end
  end
end
