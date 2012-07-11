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
use Cwd;

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
	$self->{config_filename} = File::Spec->catfile($self->{certdir}, $self->{entryname}."_sscep.cnf");
	
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
            next if $key eq "INHERIT";
            $self->{OPTIONS}->{$section}->{$key} = $value if $value;
        }
    }
    
    return 1;
}

sub execute {
	my $self = shift;
	my $operation = shift;
	
	my @cmd = (qq("$self->{cmd}"),
           "$operation",
           '-f',
           qq("$self->{config_filename}")
	);
	
	my $cmd = join(' ', @cmd);
	CertNanny::Logging->debug("Exec: $cmd");
	`$cmd`;
	if ($? != 0) {
	    CertNanny::Logging->error("Could not retrieve CA certs");
	    return;
	}
	
	return $?;
}
# Enroll needs
# PrivateKeyFile
# CertReqFile
# SignKeyFile
# SignCertFile
# LocalCertFile
# EncCertFile
sub enroll {
	my $self = shift;
	my %options = (@_,);
	#($volume,$directories,$file) = File::Spec->splitpath( $path );
	my $olddir = getcwd();
	chdir $self->{certdir};
	foreach my $section (keys %options) {
		while (my ($key, $value) = each($options{$section})) {
            $options{$section}->{$key} = File::Spec->abs2rel($value);
        }
	}
	$self->readConfig(\%options);
	$self->writeConfigFile();

	CertNanny::Logging->info("Sending request");

	#print Dumper $self->{STATE}->{DATA};

	my %certs = $self->getCA();
	if ( !%certs ) {
		CertNanny::Logging->error("Could not get CA certs");
		return;
	}
=comment
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
=cut
	my $rc;
	eval {
		local $SIG{ALRM} = sub { die "alarm\n" };    # NB: \n required
		eval { alarm 120 };    # eval not supported in perl 5.7.1 on win32
		$self->readConfig(\%options);
		$self->writeConfigFile();
		$rc = $self->execute("enroll") / 256;
		eval { alarm 0 };      # eval not supported in perl 5.7.1 on win32
		CertNanny::Logging->info("Return code: $rc");
	};
	
	chdir $olddir;
	
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
=comment
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
=cut
	return 1;
}

sub writeConfigFile {
	my $self = shift;
	
	open(my $configfile, ">", $self->{config_filename}) or die "Cannot write $self->{config_filename}";
	
	foreach my $section ( keys $self->{OPTIONS}) {
		print $configfile "[$section]\n";
        while (my ($key, $value) = each($self->{OPTIONS}->{$section})) {
        	if(-e $value and $^O eq "MSWin32") {
	        	#on Windows paths have a backslash, so in the string it is \\.
	        	#In the config it must keep the doubled backslash so the actual 
	        	#string would contain \\\\. Yes this is ridiculous...
				$value =~ s/\\/\\\\/g;        		
        	}
            print $configfile "$key=$value\n";
        }
    }
    
    close $configfile;
	return 1;
}

sub getCA {
	
	my $self= shift;
	my $config = shift;
	unless($self->{certs}->{RACERT} and $self->{certs}->{CACERTS}) {
		my $olddir = getcwd();
		chdir $self->{certdir};
		$config->{sscep}->{CACertFile} =  'cacert';
		
		$self->readConfig($config);
		$config = $self->{OPTIONS};
		
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
	    
	    $self->writeConfigFile();
	    if($self->execute("getca") != 0) {
	    	return;
	    }
	    
	    my $scepracert = File::Spec->catfile($self->{certdir}, $config->{sscep}->{CACertFile} . "-0");
	    
	    # collect all ca certificates returned by the SCEP command
	    my @cacerts = ();
	    $ii = 1;
	
	    my $certfile = $config->{sscep}->{CACertFile} . "-$ii";
	    while (-r $certfile) {
	        my $certformat = 'PEM'; # always returned by sscep
	        my $certinfo = CertNanny::Util->getcertinfo(CERTFILE => $certfile,
	                          CERTFORMAT => 'PEM');
	    
	        if (defined $certinfo) {
	            push (@cacerts, { CERTINFO => $certinfo,
	                      CERTFILE => $certfile,
	                      CERTFORMAT => $certformat,
	                  });
	        }
	        $ii++;
	        $certfile = $config->{sscep}->{CACertFile} . "-$ii";
	    }
	    
	    $self->{certs}->{CACERTS} = \@cacerts;
		$self->{certs}->{RACERT} = $scepracert;
		chdir $olddir;
	}
	
	my %certs = (
		CACERTS => $self->{certs}->{CACERTS},
	);
	
	if ( -r $self->{certs}->{RACERT} ) {
		$certs{RACERT} = $self->{certs}->{RACERT};		
	}
	return %certs;
=comment	
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
		chdir $olddir;
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
	chdir $olddir;
	$self->{STATE}->{DATA}->{SCEP}->{CACERTS} = \@cacerts;

	if ( -r $scepracert ) {
		$self->{STATE}->{DATA}->{SCEP}->{RACERT} = $scepracert;
		return $scepracert;
	}
	return;
=cut
}

sub getNextCA {
	return;
}

sub defaultOptions {
	my $self = shift;
	
	my %options = (
		sscep_engine_capi => {
			'new_key_location' => 'REQUEST',
		},
		
		sscep_enroll => {
			'PollInterval' => 5,
			'MaxPollCount' => 1
		}
	);
	
	return \%options;
}

1;

=head1 NAME

CertNanny::Enroll::Sscep - Enrolling new certificates via the sscep protocol.

=head1 SYNOPSIS

    my $sscep = CertNanny::Enroll::Sscep->new($entry_options, $config, $entryname);
    $sscep->getCA();
    $sscep->enroll();


=head1 DESCRIPTION

This module implements the CertNanny::Enroll interface. By running the associated function, it is possible to renew certificates.

=head1 FUNCTIONS

=head2 Function List

=over 4

C<new()>

C<enroll()>

C<getCA()>

C<getNextCA()>

C<defaultOptions()>

C<execute()>

C<readConfig()>

C<setOption()>

=back

=head2 Function Descriptions

=over 4

=item new( $entry_options, $config, $entryname)

Instantiates the sscep client with an instance. The client managing it should only use one instance per certificate which should be renewed.
Configuration is passed through three options:

=over 4

=item $entry_options

Has the options for the specific entry which is all options that are keystore specific. Typically options defined via "keystore." settings.
All options of the format keystore.LABEL.enroll (or $entry_options->{enroll}) are read here with C<readConfig()>.

=item $config

Reads the global configuration. Typical settings here are the loglevel and sscep.cmd. Only specific settings will be loaded, the rest will be discarded.

=item $entryname

The name (label) of the entry. This is the name assinged via keystore.LABEL. where LABEL will be the name. Is expected to be a string.

=back

=item enroll( %options )

The actual renewal of the certificate. The %options hash will consist of all possible configuration params with the standard format.
See C<readConfig()> for details about possible options. sscep expects all files to be in an unencrypted PEM format. Thus is it necessary to convert all
keys to a PEM format without a passphrase. If, however, an engine should be used, you can keep the format in a way the engine understands.
This can either be a PEM formatted file or any file the engine understands (e.g. proprietary formats, IDs).
Typically a hash with at least the key "sscep_enroll" is passed. This hash typically has the following keys:

=over 4

=item PrivateKeyFile
	
Full path to the file of the newly generated csr. This is the private key you want a certificate for.

=item CertReqFile

The generated CSR for the new private key

=item SignKeyFile

With this option your request will be signed. It is your old key for which you have a valid certificate. If omitted, initial enrollment will be performed.

=item SignCertFile

The corresponding, still valid certificate to SignKeyFile

=item LocalCertFile

The target filename for the new certificate

=back

=item getCA()

Retrieves all CA certificates from the SCEP-server. Typically the first certificate returned will be the SCEP RA certificate.

=item getNextCA()

Root Key Roll-Over. Not Yet Implemented.

=item defaultOptions()

Internal function. Stores default options which get overwritten by options that are passed. Modify this if you want other defaults for sscep.

=item execute()

Internal function. Perform an sscep command based on the current configuration. Normally you do not need to call this.

=item readConfig( %hash )

Internal function. Reads the configuration from a passed hash. Gets called by C<new()>. The keys of %hash describe section names. Each element is another hash which consists of key => value pairs for this section.
Refer to the sscep documentation and example configuration fine (.cnf extension) on the available optiosn. The syntax used is OpenSSL configuration syntax.

=item setOption( $key, $value, $section)

Function to modify single options. Sets the value $value for key $key in section $section. All three paramters are required for this to work. Refer to the sscep documentation for information on key, value and section.