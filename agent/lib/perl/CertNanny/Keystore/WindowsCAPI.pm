#
# CertNanny - Automatic renewal for X509v3 certificates using SCEP
# 2005-02 Martin Bartosch <m.bartosch@cynops.de>
#
# This software is distributed under the GNU General Public License - see the
# accompanying LICENSE file for more details.
#

package CertNanny::Keystore::WindowsCAPI;

use base qw(Exporter CertNanny::Keystore::OpenSSL);

use strict;
use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);
use Exporter;
use Carp;

use IO::File;
use File::Spec;
use File::Copy;
use Data::Dumper;
use CertNanny::Util;
use Cwd;

$VERSION = 0.01;

#implement new?
sub new
{
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my %args = ( 
        @_,         # argument pair list
    );

    my $self = {};
    bless $self, $class;

    $self->{OPTIONS} = \%args;


    # Througout this class you will be able to access entry configuration
    # settings via
    # $self->{OPTIONS}->{ENTRY}->{setting}
    # It is possible to introduce new entry settings this way you might
    # need for your keystore implementation. 
    # It is also possible to introduce additional hierarchy layers in
    # the configuration, e. g. if you have a
    #   keystore.foobar.my.nifty.setting = bla
    # you will be able to access this via
    # $self->{OPTIONS}->{ENTRY}->{my}->{nifty}->{setting}
    # Be sure to check all configuration settings for plausiblitiy.


    # You will have to obtain the keystore pin somehow, for some keystores
    # it will be configured in certnanny's config file, for others you
    # might want to deduce it from the keystore itself
    #my $pin = "";
#    $pin = $self->{OPTIONS}->{ENTRY}->{pin};
    if (! exists $self->{OPTIONS}->{ENTRY}->{pin}) {
	    $self->{OPTIONS}->{ENTRY}->{pin} = "";
    }

    # export the pin to this instance
    $self->{PIN} = $self->{OPTIONS}->{ENTRY}->{pin};
    
    # sample sanity checks for configuration settings
     foreach my $entry (qw( location )) {
		if (! defined $self->{OPTIONS}->{ENTRY}->{$entry} ) {
			croak("keystore.$entry $self->{OPTIONS}->{ENTRY}->{$entry} not defined.");
			return;
		}
	}
    
    $self->{OPTIONS}->{ENTRY}->{storename} ||= 'MY';
    $self->{OPTIONS}->{ENTRY}->{storelocation} ||= 'machine';
    
    $self->{OPTIONS}->{ENTRY}->{enroll}->{sscep}->{engine} = "sscep_engine";
    $self->{OPTIONS}->{ENTRY}->{enroll}->{sscep_engine}->{engine_id} = "capi";
    $self->{OPTIONS}->{ENTRY}->{enroll}->{sscep_engine}->{dynamic_path} = "capi";

	#$self->{STORE}=$self->openstore( $self->{OPTIONS}->{ENTRY}->{storename},$self->{OPTIONS}->{ENTRY}->{storelocation});
    # the rest should remain untouched

    # get previous renewal status
    #$self->retrieve_state() || return;

    # check if we can write to the file
    #$self->store_state() || croak "Could not write state file $self->{STATE}->{FILE}";

    # instantiate keystore
    return $self;
}

sub getcert()
{
	my $self = shift;
	my $certdata = "";
	CertNanny::Logging->debug("Called getcert() for WindowsCAPI");
	my $serial;
	my $returned_data = "";
	# delete any old certificates, just to be sure
	foreach my $cert (glob File::Spec->catfile($self->{OPTIONS}->{ENTRY}->{statedir}, 'Blob*.crt')) {
    	unlink $cert;
    }
	my $derfile_tmp = $self->CertutilWriteCerts(( SERIAL => $serial ));
	unless(defined($derfile_tmp)) {
		CertNanny::Logging->debug("No serial was defined before so all certs were dumped and are now parsed");
		my $olddir = getcwd();
		chdir $self->{OPTIONS}->{ENTRY}->{statedir};
		my @certs = glob "Blob*.crt";
		my $active_cert;
		foreach my $certfilename (@certs) {
			my $certinfo = $self->getcertinfo( CERTFILE => $certfilename );
			CertNanny::Logging->debug("Parsing certificate with filname $certfilename and subjectname $certinfo->{SubjectName}");
			my $notbefore = CertNanny::Util::isodatetoepoch($certinfo->{NotBefore});
			my $notafter = CertNanny::Util::isodatetoepoch($certinfo->{NotAfter});
			my $now = time;
			CertNanny::Logging->debug("Searching for $self->{OPTIONS}->{ENTRY}->{location} in $certinfo->{SubjectName} and NotAfter $notafter where current time is $now");
			CertNanny::Logging->debug("Result of index: ". index($certinfo->{SubjectName}, $self->{OPTIONS}->{ENTRY}->{location}));
			if (index($certinfo->{SubjectName}, $self->{OPTIONS}->{ENTRY}->{location}) != -1 && $notafter > $now) {
				CertNanny::Logging->debug("Found something!");
				my $active_notafter = CertNanny::Util::isodatetoepoch($active_cert->{NotAfter}) if (defined($active_cert));
				if(!defined($active_cert) || $active_notafter < $notafter) {
					$active_cert = $certinfo;
					$serial = $certinfo->{SerialNumber};
					$serial =~ s/://g;
					CertNanny::Logging->debug("The current certificate is the newest and thus will be used from hereon");
				}
			}
		}
		chdir $olddir;
		if(!defined($serial)) {
			CertNanny::Logging->error("Could not retrieve a valid certificate from the keystore");
			return;
		}
		$derfile_tmp = $self->CertutilWriteCerts(( SERIAL => $serial ));
	}
	my @cmd;
	my $cmd;
	my $openssl = $self->{OPTIONS}->{CONFIG}->get('cmd.openssl', 'FILE');
	@cmd = (qq("$openssl"), 'x509', '-in', qq("$derfile_tmp"), '-inform', 'DER');
	$cmd = join(" ", @cmd);
	CertNanny::Logging->debug("Execute: $cmd");
	$certdata  = `$cmd`;
	CertNanny::Logging->debug("Dumping resulting certificate in PEM format:\n$certdata");
	return { CERTDATA => $certdata,
	      CERTFORMAT => 'PEM'};
}

sub CertutilWriteCerts()
{
	my $self = shift;
	my %args = (@_,);
	$args{OPTIONS} = ['-split'];
	push($args{OPTIONS}, '-user') if $self->{OPTIONS}->{ENTRY}->{storelocation} eq "user";
	$args{COMMAND} = '-store';
	$args{OUTFILE} = $self->gettmpfile() if defined $args{SERIAL};
	CertNanny::Logging->debug("Calling certutil to retrieve certificates.");
	my $outfile_tmp = $self->CertUtilCmd(%args);
	return $outfile_tmp;
}

sub CertUtilDeleteCert() {
	my $self = shift;
	my %args = (@_,);
	$args{OPTIONS} = [];
	push($args{OPTIONS}, '-user') if $self->{OPTIONS}->{ENTRY}->{storelocation} eq "user";
	$args{COMMAND} = '-delstore';
	my $serial = $args{SERIAL};
	my $store = $args{STORE} || "My";
	unless($serial and $store) {
	    CertNanny::Logging->error("A deletion was requested, but either no serial or no storename was provided.");
	    return;
	}
	CertNanny::Logging->debug("Deleting ceritifcate with serial $serial from store $store");
	$self->CertUtilCmd(%args);
	return !$?;
}

sub CertUtilCmd() {
	my $self = shift;
	my %args = (@_,);
	my $serial = $args{SERIAL} if defined $args{SERIAL};
	my $store = $args{STORE} || "My";
	my $outfile_tmp = $args{OUTFILE} if defined $args{OUTFILE};
	
	CertNanny::Logging->debug("Serial is $serial.") if defined($serial);
	
	my @cmd;
	push(@cmd, 'certutil');
	foreach my $option (@{$args{OPTIONS}}) {
		push(@cmd, $option);
	}
	push(@cmd, $args{COMMAND});
	push(@cmd, qq("$store")); # NOTE: It is *mandatory* to have double quotes here!
	push(@cmd, $serial) if defined $serial;
	push(@cmd, $outfile_tmp) if defined $outfile_tmp;
	my $cmd = join(" ", @cmd);
	my $olddir = getcwd();
	chdir ($args{TARGETDIR} ||$self->{OPTIONS}->{ENTRY}->{statedir});
	my @certs = glob "Blob*.crt";
	foreach my $cert (@certs) {
		unlink $cert;
	}
	CertNanny::Logging->debug("Execute: $cmd.");
	my $cmd_output = `$cmd`;
	chdir $olddir;
	CertNanny::Logging->debug("Dumping output of above command:\n $cmd_output");
	CertNanny::Logging->debug("Output was written to $outfile_tmp") if defined($outfile_tmp);
	return $outfile_tmp;
}


sub createrequest()
{
	my $self = shift;
    my %args = ( 
        @_,         # argument pair list
    );
	
	#open template inf file
	my $inf_file_in = $self->{OPTIONS}->{CONFIG}->get('path.certreqinf', 'FILE');
	open INF_FILE_IN, "<", $inf_file_in
		or CertNanny::Logging->error("createrequest(): Could not open input file: $inf_file_in");
	my $inf_file_out = $self->gettmpfile();
	my $out_file_str;
	$out_file_str .= $_ while <INF_FILE_IN>;
	close INF_FILE_IN;
	$out_file_str = sprintf($out_file_str, $self->{CERT}->{INFO}->{SubjectName});
	my $result;
	
	if(! CertNanny::Util->write_file(
		FILENAME => $inf_file_out,
		CONTENT => $out_file_str,
		FORCE => 1,
	)) {
		CertNanny::Logging->error("createrequest(): Could not write temporary inffile $inf_file_out");
		return;
	}
	
	my $requestfile = $self->{OPTIONS}->{ENTRYNAME} . ".csr";
	$result->{REQUESTFILE} = File::Spec->catfile($self->{OPTIONS}->{ENTRY}->{statedir}, $requestfile);
	
	unless($self->checkRequestSanity()){
	    CertNanny::Logging->error("createrequest(): Sanitycheck could not resolve all problems. Please fix manually.");
	    return;
	}
	
	# if the file exists, the sanity check has checked that everything is just fine...
	unless (-e $result->{REQUESTFILE}) { 
		my @cmd = ('certreq', '-new', qq("$inf_file_out"), qq("$result->{REQUESTFILE}"));
		my $cmd = join(' ', @cmd);
		`$cmd`;
		if($? != 0) {
			CertNanny::Logging->error("createrequest(): Executing certreq cmd error: $cmd");
			return;
		}
	}
	
	return $result;
}

sub getStoreCerts() {
	my $self = shift;
	my $store = shift;
	
	$self->CertutilWriteCerts((STORE => $store));
	my $olddir = getcwd();
	chdir $self->{OPTIONS}->{ENTRY}->{statedir};
	my @certs = glob "Blob*.crt";
	my @certinfos;
	foreach my $cert (@certs) {
		my $certinfo = $self->getcertinfo( CERTFILE => $cert );
		push(@certinfos, $certinfo);
	}
	chdir $olddir;
	
	
	return @certinfos;
}

# check if both a csr AND a key exist AND check if they match
# this functions cleans up all irregularities
# this means, after this function was executed, either a valid csr + key exist
# or both were removed. Thus the existence of a CSR indicated that everything is fine
sub checkRequestSanity() {
	my $self = shift;
	# Steps:
	CertNanny::Logging->debug("Checking request sanity.");
	# 1. read all keys from REQUEST store
	my @certs = $self->getStoreCerts("REQUEST");
	# 2. read csr
	my $csrfile = File::Spec->catfile($self->{OPTIONS}->{ENTRY}->{statedir}, $self->{OPTIONS}->{ENTRYNAME} . ".csr");
	# 3. if csr does not exist
	unless(-e $csrfile) {
		CertNanny::Logging->debug("No CSR was found under $csrfile for keystore " . $self->{OPTIONS}->{ENTRYNAME} . ". Checking if there is a pending request in keystore that matched Certificate subject " . $self->{OPTIONS}->{ENTRY}->{SubjectName} . ".");
		# 3.1. if object with same subject name as current cert exists
		my @delete_certs;
		foreach my $cert (@certs) {
			if((index $self->{CERT}->{INFO}->{SubjectName}, $cert->{SubjectName}) != -1) {
				push(@delete_certs, $cert);
			}
		}
		
		if(@delete_certs) {
			# 3.1.1 delete the objects
			CertNanny::Logging->info("There is at least one old pending request in the keystore although no CSR was found for it. All pending requests that have the same subject as the current ceritficate will be deleted.");
			foreach my $cert (@delete_certs) {
				my $serial = $cert->{SerialNumber};
				$serial =~ s/://g;
				unless($self->CertUtilDeleteCert(( SERIAL => $serial, STORE => "REQUEST"))) {
				    CertNanny::Logging->error("Could not delete certificate with serial $serial from store REQUEST");
				    return;
				}
			}
						
		}
		return 1;

	} 
	
	# 4. if csr exists
	if(-e $csrfile) {
		# 4.1 if no key in REQUEST
		unless(@certs) {
		    CertNanny::Logging->info("There is no pending request in the keystore so the current csr will be deleted.");
			# 4.1.1 delete the csr
			unless(unlink $csrfile) {
			    CertNanny::Logging->error("Could not delete csr $csrfile. Please remove manually.");
			    return;
			}
			return 1;
		}
		
		# 4.2 if csr does not match REQUEST
		my $csr = CertNanny::Util->getcsrinfo(( CERTFILE => $csrfile ));
		my $request_key;
		my @delete_certs;
		foreach my $cert (@certs) {
			if(index($cert->{SubjectName}, $csr->{SubjectName}) != -1) {
				if($cert->{Modulus} eq $csr->{Modulus}) {
					$request_key = $cert;
				} else {
					push(@delete_certs, $cert);
				}
			}
		}
		
		unless($request_key) {
		    my $subject = $csr->{SubjectName};
		  CertNanny::Logging->info("The existing csr does not match any currently pending request in the keystore so the csr and all pending requests with subject $subject will be deleted.");   
		}
		unless( defined $request_key ){
			# 4.2.1 delete the csr
			unless(unlink $csrfile) {
			    CertNanny::Logging->error("Could not delete csr $csrfile. Please remove manually.");
			    return;
			}
		}
		
		# 4.2.2 delete the object
		foreach my $cert (@delete_certs) {
			my $serial = $cert->{SerialNumber};
			$serial =~ s/://g;
			CertNanny::Logging->debug("Deleting certificate with serial $serial");
			unless($self->CertUtilDeleteCert(( SERIAL => $serial, STORE => "REQUEST"))) {
			    CertNanny::Logging->error("Could not delete certificate with serial $serial from store REQUEST");
			    return;
			}
		}
	}
	
	return 1;
}

sub installcert()
{
	# convert cert to pkcs#12
	# execute import_cert.exe import test100-cert.pfx
	my $self = shift;
    my %args = ( 
        @_,         # argument pair list
    );
	my $ret = 1;
	
	#my $keyfile = $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{KEYFILE};
	my $certfile = $args{CERTFILE};
	my @cmd = ('certreq', '-accept', qq("$certfile"));
	my $cmd = join(" ", @cmd);
	CertNanny::Logging->debug("Execute: $cmd");
	my $cmd_output = `$cmd`;
	CertNanny::Logging->debug("certreq output:\n$cmd_output");
	if ($? != 0) {
		CertNanny::Logging->error("installcert(): Certificate could not be imported. Output of command $cmd was:\n$cmd_output");
		return;
	}
	
	# if everything was successful, we need to execute cleanup
	my $requestfile = $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{REQUESTFILE};
	# delete request, otherwise certnanny thinks we have a pending request...
	if(-e $requestfile) {
		unless(unlink $requestfile) {
			CertNanny::Logging->error("installcert(): Could not delete the old csr. Since the certificate was already installed, this is *critical*. Delete it manually or the next renewal will fail.");
		}
	}
	
	# TODO delete the old certificate (or archive it?)
	my $newcert_info = CertNanny::Util->getcertinfo(( CERTFILE => $certfile, CERTFORMAT => 'PEM' ));
	CertNanny::Logging->info("Deleting old certificate from keystore");
	my @store_certs = $self->getStoreCerts();
	foreach my $storecert (@store_certs) {
	    my $newcert_subject = $newcert_info->{SubjectName};
	    my $newcert_serial = $newcert_info->{SerialNumber};
	    my $storecert_subject = $storecert->{SubjectName};
	    my $storecert_serial = $storecert->{SerialNumber};
	    if( $storecert_subject eq $newcert_subject && $storecert_serial ne $newcert_serial) {
	        my $delserial = $storecert_serial;
	        $delserial =~ s/://g;
	        CertNanny::Logging->debug("Deleting certificate with serial $delserial");
	        unless($self->CertUtilDeleteCert((SERIAL => $delserial))) {
	            CertNanny::Logging->error("Could not delete the old certificate. The next update will fail if this is not fixed!");
	            $ret = undef;
	        }
	    }
	}
	
	return $ret;

=comment
	# ..\openssl-mingw\bin\openssl.exe pkcs12 -export -inkey test100-key.pem -in test100-cert.pem -out test100-cert.pfx
	my $openssl = $self->{OPTIONS}->{openssl_shell};
	my @cmd = (qq("$openssl"),
			'pkcs12',
			'-export',
			'-inkey',
			qq("$keyfile"),
			'-in',
			qq("$certfile"),
			'-out',
			qq("$outfile"),
	);
	
	my $cmd = join(' ', @cmd);
	CertNanny::Logging->debug("Execute: ");
	
	$output->{CERTDATA} = `$cmd`;
	
	if ($? != 0) {
	CertNanny::Logging->error("installcert(): Could not convert cert to PKCS12");
	return;
	}
	
	
	
	return $output;
=cut
	
}