#
# CertNanny - Automatic renewal for X509v3 certificates using SCEP
# 2011-05 Stefan Kraus <stefan.kraus05@gmail.com>
#
# This software is distributed under the GNU General Public License - see the
# accompanying LICENSE file for more details.
#
package CertNanny::Enroll::Sscep;

use base qw(Exporter);
use CertNanny::Logging;
use File::Spec;
use vars qw( $VERSION );
use Exporter;

$VERSION = 0.10;

sub new {
	my $proto = shift;
	my $class = ref($proto)  || $proto;
	my $entry_options = shift;
	my $config = shift;
    my $entryname = shift;
	my $self = {};
	
	bless $self, $class;
	# type is determined, now delete it so only sections will be scanned.
	delete $entry_options->{enroll}->{type};
	$self->{OPTIONS} = $self->defaultOptions();
	$self->readConfig($entry_options->{enroll});
	# SCEP url
#	$self->{URL} = $config->{URL} or die("No SCEP URL given");
    if(! defined $self->{OPTIONS}->{sscep}->{URL}) {
	    CertNanny::Logging->error("scepurl not specified for keystore");
	    return;
    }
	
	
	$self->{OPTIONS}->{sscep}->{Verbose} = "True" if $config->get("loglevel") >= 5;
	$self->{OPTIONS}->{sscep}->{Debug} = "True" if $config->get("loglevel") >= 6;
	
	$self->{certdir} = $entry_options->{scepcertdir};
	if(! defined $self->{certdir}) {	
	    CertNanny::Logging->error("scepcertdir not specified for keystore");
	    return;
	}
	$self->{entryname} = $entryname;
	$self->{cmd} = $config->get('cmd.sscep');
	$self->{config_file} = File::Spec->catfile($self->{certdir}, $self->{entryname}."_sscep.cnf");
	
	return $self;
}

sub setOption {
	my $self = shift;
	my $key = shift;
	my $value = shift;
	my $section = shift;
	
	#must provide all three params
	return 0 if(!($key and $value and $section));
	
	$self->{OPTIONS}->{$section}->{$key} = $value;
	CertNanny::Logging->debug("Option $key in section $section set to $value.");
	return 1;
}

sub readConfig {
	my $self = shift;
	my $config = shift;
	
	foreach my $section ( keys $config) {
        next if $section eq "INHERIT";
        while (my ($key, $value) = each($config->{$section})) {
            next if $section eq "INHERIT";
            $self->{OPTIONS}->{$section}->{$key} = $value if $value;
        }
    }
    
    return 1;
}

sub execute {
	my $self = shift;
	my $operation = shift;
	
	my @cmd = (qq("$self->{cmd}"),
           qq('$operation'),
           '-f',
           qq("$self->config_file")
	);
	
	my $cmd = join(' ', @cmd);
	CertNanny::Logging->debug("Exec: $cmd");
	`$cmd`;
	if ($? != 0) {
	    CertNanny::Logging->error("Could not retrieve CA certs");
	    return;
	}
}

sub enroll {
	my $self = shift;

	CertNanny::Logging->info("Sending request");

	#print Dumper $self->{STATE}->{DATA};

	if ( !$self->getCA() ) {
		CertNanny::Logging->error("Could not get CA certs");
		return;
	}

	my $requestfile =
	  $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{REQUESTFILE};
	my $keyfile = $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{KEYFILE};
	my $pin     = $self->{PIN} || $self->{OPTIONS}->{ENTRY}->{pin};
	my $sscep   = $self->{OPTIONS}->{CONFIG}->get('cmd.sscep');
	my $scepurl = $self->{OPTIONS}->{ENTRY}->{scepurl};
	my $scepsignaturekey     = $self->{OPTIONS}->{ENTRY}->{scepsignaturekey};
	my $scepchecksubjectname = $self->{OPTIONS}->{ENTRY}->{scepchecksubjectname}
	  || 'no';
	my $scepracert = $self->{STATE}->{DATA}->{SCEP}->{RACERT};

	if ( !exists $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{CERTFILE} ) {
		my $certfile = $self->{OPTIONS}->{ENTRYNAME} . "-cert.pem";
		$self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{CERTFILE} =
		  File::Spec->catfile( $self->{OPTIONS}->{ENTRY}->{statedir},
			$certfile );
	}

	my $newcertfile = $self->{STATE}->{DATA}->{RENEWAL}->{REQUEST}->{CERTFILE};
	my $openssl     = $self->{OPTIONS}->{openssl_shell};

	CertNanny::Logging->debug("request: $requestfile");
	CertNanny::Logging->debug("keyfile: $keyfile");
	CertNanny::Logging->debug("sscep: $sscep");
	CertNanny::Logging->debug("scepurl: $scepurl");
	CertNanny::Logging->debug("scepsignaturekey: $scepsignaturekey");
	CertNanny::Logging->debug("scepchecksubjectname: $scepchecksubjectname");
	CertNanny::Logging->debug("scepracert: $scepracert");
	CertNanny::Logging->debug("newcertfile: $newcertfile");
	CertNanny::Logging->debug("openssl: $openssl");

	# get unencrypted new key in PEM format
	my $newkey = $self->convertkey(
		KEYFILE   => $keyfile,
		KEYPASS   => $pin,
		KEYFORMAT => 'PEM',
		KEYTYPE   => 'OpenSSL',
		OUTFORMAT => 'PEM',
		OUTTYPE   => 'OpenSSL',

		# no pin
	);

	if ( !defined $newkey ) {
		CertNanny::Logging->error("Could not convert new key");
		return;
	}

	# write new PEM encoded key to temp file
	my $requestkeyfile = $self->gettmpfile();
	CertNanny::Logging->debug("requestkeyfile: $requestkeyfile");
	chmod 0600, $requestkeyfile;

	if (
		!CertNanny::Util->write_file(
			FILENAME => $requestkeyfile,
			CONTENT  => $newkey->{KEYDATA},
			FORCE    => 1,
		)
	  )
	{
		CertNanny::Logging->error(
			"Could not write unencrypted copy of new file to temp file");
		return;
	}

	my @cmd;

	my @autoapprove = ();
	my $oldkeyfile;
	my $oldcertfile;
	if ( $scepsignaturekey =~ /(old|existing)/i ) {

		# get existing private key from keystore
		my $oldkey = $self->getkey();
		if ( !defined $oldkey ) {
			CertNanny::Logging->error(
				"Could not get old key from certificate instance");
			return;
		}

		# convert private key to unencrypted PEM format
		my $oldkey_pem_unencrypted = $self->convertkey(
			%{$oldkey},
			OUTFORMAT => 'PEM',
			OUTTYPE   => 'OpenSSL',
			OUTPASS   => '',
		);

		if ( !defined $oldkey_pem_unencrypted ) {
			CertNanny::Logging->error("Could not convert (old) private key");
			return;
		}

		$oldkeyfile = $self->gettmpfile();
		chmod 0600, $oldkeyfile;

		if (
			!CertNanny::Util->write_file(
				FILENAME => $oldkeyfile,
				CONTENT  => $oldkey_pem_unencrypted->{KEYDATA},
				FORCE    => 1,
			)
		  )
		{
			CertNanny::Logging->error(
				"Could not write temporary key file (old key)");
			return;
		}

		$oldcertfile = $self->gettmpfile();
		if (
			!CertNanny::Util->write_file(
				FILENAME => $oldcertfile,
				CONTENT  => $self->{CERT}->{RAW}->{PEM},
				FORCE    => 1,
			)
		  )
		{
			CertNanny::Logging->error(
				"Could not write temporary cert file (old certificate)");
			return;
		}

		@autoapprove = ( '-K', qq("$oldkeyfile"), '-O', qq("$oldcertfile"), );
	}
	my @checksubjectname = ();
	@checksubjectname = ('-C') if $scepchecksubjectname =~ /yes/i;
	my @verbose = ();
	push @verbose, '-v' if CertNanny::Logging->loglevel() >= 5;
	push @verbose, '-d' if CertNanny::Logging->loglevel() >= 6;
	@cmd = (
		qq("$sscep"), 'enroll',
		'-u',         qq($scepurl),
		'-c',         qq("$scepracert"),
		'-r',         qq("$requestfile"),
		'-k',         qq("$requestkeyfile"),
		'-l',         qq("$newcertfile"),
		@autoapprove, @checksubjectname,
		@verbose,     '-t',
		'5',          '-n',
		'1',
	);

	CertNanny::Logging->debug( "Exec: " . join( ' ', @cmd ) );

	my $rc;
	eval {
		local $SIG{ALRM} = sub { die "alarm\n" };    # NB: \n required
		eval { alarm 120 };    # eval not supported in perl 5.7.1 on win32
		$rc = run_command( join( ' ', @cmd ) ) / 256;
		eval { alarm 0 };      # eval not supported in perl 5.7.1 on win32
		CertNanny::Logging->info("Return code: $rc");
	};
	unlink $requestkeyfile;
	unlink $oldkeyfile  if ( defined $oldkeyfile );
	unlink $oldcertfile if ( defined $oldcertfile );

	if ($@) {

		# timed out
		die unless $@ eq "alarm\n";    # propagate unexpected errors
		CertNanny::Logging->info("Timed out.");
		return;
	}

	if ( $rc == 3 ) {

		# request is pending
		CertNanny::Logging->info("Request is still pending");
		return 1;
	}

	if ( $rc != 0 ) {
		CertNanny::Logging->error("Could not run SCEP enrollment");
		return;
	}

	if ( -r $newcertfile ) {

		# successful installation of the new certificate.
		# parse new certificate.
		# NOTE: in previous versions the hooks reported the old certificate's
		# data. here we change it in a way that the new data is reported
		my $newcert;
		$newcert->{INFO} = $self->getcertinfo(
			CERTFILE   => $newcertfile,
			CERTFORMAT => 'PEM'
		);

		# build new certificate chain
		$self->{STATE}->{DATA}->{CERTCHAIN} =
		  $self->buildcertificatechain($newcert);

		if ( !defined $self->{STATE}->{DATA}->{CERTCHAIN} ) {
			CertNanny::Logging->error(
"Could not build certificate chain, probably trusted root certificate was not configured"
			);
			return;
		}

		$self->executehook(
			$self->{OPTIONS}->{ENTRY}->{hook}->{renewal}->{install}->{pre},
			'__NOTAFTER__'          => $self->{CERT}->{INFO}->{NotAfter},
			'__NOTBEFORE__'         => $self->{CERT}->{INFO}->{NotBefore},
			'__NEWCERT_NOTAFTER__'  => $newcert->{INFO}->{NotAfter},
			'__NEWCERT_NOTBEFORE__' => $newcert->{INFO}->{NotBefore},
		);

		my $rc = $self->installcert(
			CERTFILE   => $newcertfile,
			CERTFORMAT => 'PEM'
		);
		if ( defined $rc and $rc ) {

			$self->executehook(
				$self->{OPTIONS}->{ENTRY}->{hook}->{renewal}->{install}->{post},
				'__NOTAFTER__'          => $self->{CERT}->{INFO}->{NotAfter},
				'__NOTBEFORE__'         => $self->{CERT}->{INFO}->{NotBefore},
				'__NEWCERT_NOTAFTER__'  => $newcert->{INFO}->{NotAfter},
				'__NEWCERT_NOTBEFORE__' => $newcert->{INFO}->{NotBefore},
			);

			# done
			$self->renewalstate("completed");

			return $rc;
		}
		return;
	}

	return 1;
}

sub getCA {
	
	my $self= shift;
	my $config = shift;
	
	$config->{sscep}->{CACertFile} =  File::Spec->($self->{certdir}, 'cacert');
	
	$self->readConfig($config);
	
	# delete existing ca certs
    my $ii = 0;
    while (-e $config->{sscep}->{CACertFile} . "-" . $ii) {
	    my $file = $config->{sscep}->{CACertFile} . "-" . $ii;
	    CertNanny::Logging->debug("Unlinking $file");
	    unlink $file;
	    if (-e $file) {
	        CertNanny::Logging->error("could not delete CA certificate file $file, cannot proceed");
	        return;
	    }
	    $ii++;
    }
    
    CertNanny::Logging->info("Requesting CA certificates");
    
    if(!$self->execute("getca")) {
    	return;
    }
    
    # collect all ca certificates returned by the SCEP command
    my @cacerts = ();
    $ii = 1;

    my $certfile = $config->{sscep}->{CACertFile} . "-$ii";
    while (-r $certfile) {
        my $certformat = 'PEM'; # always returned by sscep
        my $certinfo = $self->getcertinfo(CERTFILE => $certfile,
                          CERTFORMAT => 'PEM');
    
        if (defined $certinfo) {
            push (@cacerts, { CERTINFO => $certinfo,
                      CERTFILE => $certfile,
                      CERTFORMAT => $certformat,
                  });
        }
    }
	
    return unless defined $self->{CONFIG};
    CertNanny::Logging->new(CONFIG => $self->{CONFIG});
	
	
	
	
	# get root certificates
	# these certificates are configured to be trusted
	$self->{STATE}->{DATA}->{ROOTCACERTS} = $self->getrootcerts();

	my $scepracert = $self->{STATE}->{DATA}->{SCEP}->{RACERT};

	# return $scepracert if (defined $scepracert and -r $scepracert);

	my $sscep     = $self->{OPTIONS}->{CONFIG}->get('cmd.sscep');
	my $cacertdir = $self->{OPTIONS}->{ENTRY}->{scepcertdir};
	if ( !defined $cacertdir ) {
		CertNanny::Logging->error("scepcertdir not specified for keystore");
		return;
	}
	my $cacertbase = File::Spec->catfile( $cacertdir, 'cacert' );
	my $scepurl = $self->{OPTIONS}->{ENTRY}->{scepurl};
	if ( !defined $scepurl ) {
		CertNanny::Logging->error("scepurl not specified for keystore");
		return;
	}

	# delete existing ca certs
	my $ii = 0;
	while ( -e $cacertbase . "-" . $ii ) {
		my $file = $cacertbase . "-" . $ii;
		CertNanny::Logging->debug("Unlinking $file");
		unlink $file;
		if ( -e $file ) {
			CertNanny::Logging->error(
				"could not delete CA certificate file $file, cannot proceed");
			return;
		}
		$ii++;
	}

	CertNanny::Logging->info("Requesting CA certificates");

	my @cmd =
	  ( qq("$sscep"), 'getca', '-u', qq($scepurl), '-c', qq("$cacertbase") );

	CertNanny::Logging->debug( "Exec: " . join( ' ', @cmd ) );
	if ( run_command( join( ' ', @cmd ) ) != 0 ) {
		CertNanny::Logging->error("Could not retrieve CA certs");
		return;
	}

	$scepracert = $cacertbase . "-0";

	# collect all ca certificates returned by the SCEP command
	my @cacerts = ();
	$ii = 1;

	my $certfile = $cacertbase . "-$ii";
	while ( -r $certfile ) {
		my $certformat = 'PEM';                # always returned by sscep
		my $certinfo   = $self->getcertinfo(
			CERTFILE   => $certfile,
			CERTFORMAT => 'PEM'
		);

		if ( defined $certinfo ) {
			push(
				@cacerts,
				{
					CERTINFO   => $certinfo,
					CERTFILE   => $certfile,
					CERTFORMAT => $certformat,
				}
			);
		}

		$ii++;
		$certfile = $cacertbase . "-$ii";
	}
	$self->{STATE}->{DATA}->{SCEP}->{CACERTS} = \@cacerts;

	if ( -r $scepracert ) {
		$self->{STATE}->{DATA}->{SCEP}->{RACERT} = $scepracert;
		return $scepracert;
	}

	return;
}

sub getNextCA {
}

sub defaultOptions {
	my $self = shift;
	
	my %options = (
		sscep => {
			'engine' => 'sscep_engine',
		},
		
		sscep_engine_capi => {
			'new_key_location' => 'REQUEST',
		},
		
		sscep_enroll => {
			'PollInterval' => 0,
			'MaxPollTime' => 0,
			'MaxPollCount' => 0,
			'Resume' => 0,
		}
	);
	
	return \%options;
}

1;
