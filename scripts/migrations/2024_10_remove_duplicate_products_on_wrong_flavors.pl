#!/usr/bin/perl -w

# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2019 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

use CGI::Carp qw(fatalsToBrowser);

# use ProductOpener::PerlStandards;
# not available in old versions of ProductOpener running on obf, opf, opff

use ProductOpener::PerlStandards;

use ProductOpener::Config qw/:all/;
use ProductOpener::Store qw/:all/;
use ProductOpener::Tags qw/:all/;
use ProductOpener::Products qw/:all/;
use ProductOpener::Paths qw/:all/;
use ProductOpener::Data qw/:all/;
use ProductOpener::Orgs qw/:all/;
use ProductOpener::Redis qw/:all/;

use CGI qw/:cgi :form escapeHTML/;
use Storable qw/dclone/;
use Getopt::Long;
use File::Copy (qw/move/);

my $usage = <<TXT
Usage:

./2024_10_remove_duplicate_products_on_wrong_flavors.pl --flavor-code-csv [CSV file with flavor and code columns]

This script reads a tab separated CSV file on STDIN
The first column is either empty or contains a flavor: off, obf, opf, or opff
The second column is a barcode
Other columns may be included, they were generated by the 2024_10_detect_duplicate_products_in_different_flavors.pl script
The ouput of the detect duplicate script was reviewed manually to put in the first column which flavor should be kept.
Reviewed file: https://docs.google.com/spreadsheets/d/1-2WMvUC4J7iRYe3587mHJ1htIxPFyo7JLDLKHVmSum0/edit?gid=1565589772#gid=1565589772

The script will move the products that are not kept to the other-flavors-codes directory (for both product and images)

TXT
	;

my $csv_file;

GetOptions("flavor-code-csv=s" => \$csv_file,);

if (not defined $csv_file) {
	print STDERR $usage;
	exit;
}

open(my $log, ">>", "$data_root/logs/remove_duplicate_products_on_wrong_flavors.log");
print $log "remove_duplicate_products_on_wrong_flavors.pl started at " . localtime() . "\n";

my $products_collection = get_products_collection();
my $obsolete_products_collection = get_products_collection({obsolete => 1});

sub move_code_to_other_flavors_codes($code) {

	my $product_id = product_id_for_owner(undef, $code);
	my $dir = product_path_from_id($product_id);

	my $target_dir = $dir;
	$target_dir =~ s/[^0-9]//g;

	if (move("$data_root/products/$dir", "$data_root/products/other-flavors-codes/$target_dir")) {
		print STDERR "moved other flavors code $dir to $data_root/products/other-flavors-codes/$target_dir\n";
		print $log "moved other flavors code $dir to $data_root/products/other-flavors-codes/$target_dir\n";
	}
	else {
		print STDERR "could not move other flavors code $dir to $data_root/products/other-flavors-codes/$target_dir\n";
		print $log "could not move other flavors code $dir to $data_root/products/other-flavors-codes/$target_dir\n";
	}
	# Delete from mongodb
	my $id = $code;
	$products_collection->delete_one({_id => $id});
	$obsolete_products_collection->delete_one({_id => $id});

	# Also move the image dir if it exists
	if (-e "$www_root/images/products/$dir") {
		if (move("$www_root/images/products/$dir", "$www_root/images/products/other-flavors-codes/$target_dir")) {
			print STDERR
				"moved other flavors code $dir images to $www_root/images/products/other-flavors-codes/$target_dir\n";
			print $log
				"moved other flavors code $dir images to $www_root/images/products/other-flavors-codes/$target_dir\n";
		}
		else {
			print STDERR
				"could not move other flavors code $dir images to $www_root/images/products/other-flavors-codes/$target_dir\n";
			print $log
				"could not move other flavors code $dir images to $www_root/images/products/other-flavors-codes/$target_dir\n";
		}
	}

	return;
}

ensure_dir_created_or_die("$data_root/products/other-flavors-codes");
ensure_dir_created_or_die("$www_root/images/products/other-flavors-codes");

# Open CSV file
open(my $csv_fh, "<", $csv_file) or die "Could not open file $csv_file: $!";

while (my $line = <$csv_fh>) {
	chomp($line);
	my ($kept_flavor, $code) = split(/\t/, $line);
	$code = normalize_code($code);

	# Code not numeric? may be header line, skip
	if ($code !~ /^\d+$/) {
		next;
	}

	# Undefined flavor, do nothing
	if ((not defined $kept_flavor) or ($kept_flavor eq "")) {
		next;
	}

	# Check if the product exists on the current flavor
	my $product_ref = retrieve_product(product_id_for_owner(undef, $code), "include_deleted");
	if (not defined $product_ref) {
		print STDERR "code $code does not exist on the current flavor\n";
		next;
	}

	# Check if the kept flavor is equal to the flavor the script is running on
	if ($kept_flavor eq $flavor) {
		print STDERR "code $code is on the kept flavor $flavor\n";
	}
	else {
		print STDERR "code $code should be on the kept flavor $kept_flavor instead of $flavor\n";
		move_code_to_other_flavors_codes($code);

		# Push a deleted event to Redis
		push_to_redis_stream("remove-duplicates-bot", $product_ref, "deleted",
			"duplicate product: keep product on $kept_flavor, remove from $flavor", undef);
	}
}
