use VRPipe::Base;

class VRPipe::Steps::bam_to_fastq with VRPipe::StepRole {
    use VRPipe::Parser;
    
    method options_definition {
        return { };
    }
    method inputs_definition {
        return { bam_files => VRPipe::StepIODefinition->get(type => 'bam', 
                                                            max_files => -1, 
                                                            description => '1 or more name sorted bam files',
                                                            metadata => {lane => 'lane name (a unique identifer for this sequencing run, aka read group)',
                                                                         bases => 'total number of base pairs',
                                                                         reads => 'total number of reads (sequences)',
                                                                         forward_reads => 'number of forward reads',
                                                                         reverse_reads => 'number of reverse reads',
                                                                         paired => '0=single ended reads only; 1=paired end reads present',
                                                                         mean_insert_size => 'mean insert size (0 if unpaired)',
                                                                         library => 'library name',
                                                                         sample => 'sample name',
                                                                         center_name => 'center name',
                                                                         platform => 'sequencing platform, eg. ILLUMINA|LS454|ABI_SOLID',
                                                                         study => 'name of the study, put in the DS field of the RG header line',
                                                                         optional => ['library', 'sample', 'center_name', 'platform', 'study', 'mean_insert_size']}
                                                            ),
                };
    }
    method body_sub {
        return sub {
            my $self = shift;
            
            my $req = $self->new_requirements(memory => 2850, time => 1);
            
            foreach my $bam (@{$self->inputs->{bam_files}}) {
                my $meta = $bam->metadata;
                my $paired = $meta->{paired};
                
                my $source_bam = $bam->path->stringify;
                my $fastq_meta = { source_bam => $source_bam };
                foreach my $key (qw(lane insert_size mean_insert_size library sample center_name platform study)) {
                    if (defined $meta->{$key}) {
                        $fastq_meta->{$key} = $meta->{$key};
                    }
                }
                
                my $out_spec;
                my @fastqs;
                if ($paired) {
                    my $fastq = $self->output_file(output_key => 'fastq_files',
                                                   basename => "$fastq_meta->{lane}.1.fastq",
                                                   type => 'fq',
                                                   metadata => {%$fastq_meta,
                                                                reads => $meta->{forward_reads},
                                                                paired => 1});
                    my $reverse = $self->output_file(output_key => 'fastq_files',
                                                     basename => "$fastq_meta->{lane}.2.fastq",
                                                     type => 'fq',
                                                     metadata => {%$fastq_meta,
                                                                  reads => $meta->{reverse_reads},
                                                                  paired => 2});
                    @fastqs = ($fastq, $reverse);
                    
                    $fastq->add_metadata({mate => $reverse->path->stringify});
                    $reverse->add_metadata({mate => $fastq->path->stringify});
                    
                    $out_spec = 'forward => q['.$fastq->path.'], reverse => q['.$reverse->path.']';
                }
                else {
                    my $fastq = $self->output_file(output_key => 'fastq_files',
                                                   basename => "$fastq_meta->{lane}.0.fastq",
                                                   type => 'fq',
                                                   metadata => {%$fastq_meta,
                                                                reads => $meta->{reads},
                                                                bases => $meta->{bases},
                                                                avg_read_length => sprintf("%0.2f", $meta->{reads} / $meta->{bases}),
                                                                paired => 0});
                    @fastqs = ($fastq);
                    
                    $out_spec = 'single => q['.$fastq->path.']';
                }
                
                my $this_cmd = "use VRPipe::Steps::bam_to_fastq; VRPipe::Steps::bam_to_fastq->bam_to_fastq(bam => q[$source_bam], $out_spec);";
                $self->dispatch_vrpipecode($this_cmd, $req, {output_files => \@fastqs});
            }
        };
    }
    method outputs_definition {
        return { fastq_files => VRPipe::StepIODefinition->get(type => 'fq', 
                                                              max_files => -1, 
                                                              description => '1 or more fastq files',
                                                              metadata => {lane => 'lane name (a unique identifer for this sequencing run, aka read group)',
                                                                           bases => 'total number of base pairs',
                                                                           reads => 'total number of reads (sequences)',
                                                                           avg_read_length => 'the average length of reads',
                                                                           paired => '0=unpaired; 1=reads in this file are forward; 2=reads in this file are reverse',
                                                                           mate => 'if paired, the path to the fastq that is our mate',
                                                                           source_bam => 'path of the bam file this fastq file was made from',
                                                                           insert_size => 'expected library insert size (0 if unpaired)',
                                                                           mean_insert_size => 'calculated mean insert size (0 if unpaired)',
                                                                           library => 'library name',
                                                                           sample => 'sample name',
                                                                           center_name => 'center name',
                                                                           platform => 'sequencing platform, eg. ILLUMINA|LS454|ABI_SOLID',
                                                                           study => 'name of the study',
                                                                           optional => ['mate', 'library', 'sample', 'center_name', 'platform', 'study', 'insert_size', 'mean_insert_size']}),
               };
    }
    method post_process_sub {
        return sub { return 1; };
    }
    method description {
        return "Converts bam files to fastq files";
    }
    method max_simultaneous {
        return 0; # meaning unlimited
    }
    
    method bam_to_fastq (ClassName|Object $self: Str|File :$bam!, Str|File :$forward?, Str|File :$reverse?, Str|File :$single?) {
        if ((defined $forward ? 1 : 0) + (defined $reverse ? 1 : 0) == 1) {
            $self->throw("When forward is used, reverse is required, and vice versa");
        }
        if (! $forward && ! $single) {
            $self->throw("At least one of single or forward+reverse are required");
        }
        
        my $in_file = VRPipe::File->get(path => $bam);
        my @out_files;
        my @out_fhs;
        my $i = -1;
        foreach my $fq_path ($forward, $reverse, $single) {
            $i++;
            next unless $fq_path;
            push(@out_files, VRPipe::File->get(path => $fq_path));
            $out_fhs[$i] = $out_files[-1]->openw;
        }
        
        # parse bam file, convert to fastq, using OQ values if present
        my $pars = VRPipe::Parser->create('bam', {file => $in_file});
        $in_file->disconnect;
        my $pr = $pars->parsed_record();
        $pars->get_fields('QNAME', 'FLAG', 'SEQ', 'QUAL', 'OQ');
        my %pair_data;
        while ($pars->next_record()) {
            my $qname = $pr->{QNAME};
            my $flag = $pr->{FLAG};
            
            my $seq = $pr->{SEQ};
            my $oq = $pr->{OQ};
            my $qual = $oq eq '*' ? $pr->{QUAL} : $oq;
            if ($pars->is_reverse_strand($flag)) {
                $seq = reverse($seq);
                $seq =~ tr/ACGTacgt/TGCAtgca/;
                $qual = reverse($qual);
            }
            
            if ($forward && $pars->is_sequencing_paired($flag)) {
                my $key = $pars->is_first($flag) ? 'forward' : 'reverse';
                $pair_data{$key} = [$qname, $seq, $qual];
                my $f = $pair_data{forward} || [''];
                my $r = $pair_data{reverse} || [''];
                if ($f->[0] eq $r->[0]) {
                    my $fh = $out_fhs[0];
                    print $fh '@', $f->[0], "/1\n", $f->[1], "\n+\n", $f->[2], "\n";
                    $fh = $out_fhs[1];
                    print $fh '@', $r->[0], "/2\n", $r->[1], "\n+\n", $r->[2], "\n";
                }
            }
            elsif ($single) {
                my $fh = $out_fhs[2];
                print $fh '@', $qname, "\n", $seq, "\n+\n", $qual, "\n";
            }
        }
        
        foreach my $of (@out_files) {
            $of->close;
        }
        
        # check the fastq files are as expected
        my ($actual_reads, $actual_bases) = (0, 0);
        my %extra_meta;
        foreach my $out_file (@out_files) {
            $out_file->update_stats_from_disc(retries => 3);
            
            my ($these_reads, $these_bases) = (0, 0);
            my $pars = VRPipe::Parser->create('fastq', {file => $out_file});
            $in_file->disconnect;
            my $pr = $pars->parsed_record;
            while ($pars->next_record()) {
                my $id = $pr->[0];
                my $seq_len = length($pr->[1]);
                my $qual_len = length($pr->[2]);
                unless ($seq_len == $qual_len) {
                    $out_file->unlink;
                    $self->throw("Made fastq file ".$out_file->path." but sequence $id had mismatching sequence and quality lengths ($seq_len vs $qual_len)");
                }
                $these_reads++;
                $these_bases += $seq_len;
            }
            
            my $fq_meta = $out_file->metadata;
            my $expected_reads = $fq_meta->{reads};
            unless ($expected_reads == $these_reads) {
                $self->throw("Made fastq file ".$out_file->path." but there were only $these_reads reads instead of $expected_reads");
            }
            $actual_reads += $these_reads;
            
            my $expected_bases = $fq_meta->{bases};
            if ($expected_bases) {
                unless ($expected_bases == $these_bases) {
                    $out_file->unlink;
                    $self->throw("Made fastq file ".$out_file->path." but there were only $these_bases bases instead of $expected_bases");
                }
            }
            else {
                $extra_meta{$out_file->id}->{bases} = $these_bases;
            }
            $actual_bases += $these_bases;
        }
        
        my $bam_meta = $in_file->metadata;
        unless ($actual_reads == $bam_meta->{reads}) {
            foreach my $out_file (@out_files) {
                $out_file->unlink;
            }
            $self->throw("The total reads in output fastqs was only $actual_reads instead of $bam_meta->{reads}");
        }
        unless ($actual_bases == $bam_meta->{bases}) {
            foreach my $out_file (@out_files) {
                $out_file->unlink;
            }
            $self->throw("The total bases in output fastqs was only $actual_bases instead of $bam_meta->{bases}");
        }
        
        # add extra metadata we didn't know before for paired fastqs
        foreach my $out_file (@out_files) {
            my $extra = $extra_meta{$out_file->id} || next;
            my $current_meta = $out_file->metadata;
            $out_file->add_metadata({bases => $extra->{bases},
                                    avg_read_length => sprintf("%0.2f", $current_meta->{reads} / $extra->{bases})});
        }
    }
}

1;
