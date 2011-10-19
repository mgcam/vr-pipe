use VRPipe::Base;

class VRPipe::Steps::bam_strip_tags with VRPipe::StepRole {
    method options_definition {
        return { bam_tags_to_strip => VRPipe::StepOption->get(description => 'Tags to strip from the BAM files', optional => 1, default_value => [qw(OQ XM XG XO E2)]) };
    }
    method inputs_definition {
        return { bam_files => VRPipe::StepIODefinition->get(type => 'bam', max_files => -1, description => '1 or more bam files to strip tags from') };
    }
    method body_sub {
        return sub {
            my $self = shift;
            
            my $options = $self->options;
            my @tags_to_strip = @{$options->{bam_tags_to_strip}};
            
            my $req = $self->new_requirements(memory => 500, time => 1);
            foreach my $bam (@{$self->inputs->{bam_files}}) {
                my $tag_strip_bam = $self->output_file(output_key => 'tag_stripped_bam_files',
                                                       basename => $bam->basename,
                                                       type => 'bam',
                                                       metadata => $bam->metadata);
                
                my $bam_path = $bam->path;
                my $tag_strip_bam_path = $tag_strip_bam->path;
                my $this_cmd = "use VRPipe::Steps::bam_strip_tags; VRPipe::Steps::bam_strip_tags->tag_strip(q[$bam_path], q[$tag_strip_bam_path], tags_to_strip => [qw(@tags_to_strip)]);";
                $self->dispatch_vrpipecode($this_cmd, $req, {output_files => [$tag_strip_bam]});
            }
        };
    }
    method outputs_definition {
        return { tag_stripped_bam_files => VRPipe::StepIODefinition->get(type => 'bam', max_files => -1, description => 'bam files with tags stripped out') };
    }
    method post_process_sub {
        return sub { return 1; };
    }
    method description {
        return "Strips tags from bam files";
    }
    method max_simultaneous {
        return 0; # meaning unlimited
    }
    method tag_strip (ClassName|Object $self: Str|File $in_bam, Str|File $out_bam, ArrayRef[Str] :$tags_to_strip) {
        @{$tags_to_strip} > 0 || $self->throw("You must supply tags to be strippped");
        
        unless (ref($in_bam) && ref($in_bam) eq 'VRPipe::File') {
            $in_bam = VRPipe::File->get(path => file($in_bam));
        }
        unless (ref($out_bam) && ref($out_bam) eq 'VRPipe::File') {
            $out_bam = VRPipe::File->get(path => file($out_bam));
        }
        
        my $bp = VRPipe::Parser->create('bam', {file => $in_bam});
        $bp->ignore_tags_on_write(@{$tags_to_strip});
        
        $in_bam->disconnect;
        while ($bp->next_record) {
            $bp->write_result($out_bam->path);
        }
        $bp->close;
        
        $out_bam->update_stats_from_disc(retries => 3);
        
        my $expected_reads = $in_bam->metadata->{reads} || $in_bam->num_records;
        my $actual_reads = $out_bam->num_records;
        
        if ($actual_reads == $expected_reads) {
            return 1;
        }
        else {
            $out_bam->unlink;
            $self->throw("tag strip of ".$in_bam->path." to ".$out_bam->path." failed because $actual_reads reads were generated in the output bam file, yet there were $expected_reads reads in the original bam file");
        }
    }
}

1;
