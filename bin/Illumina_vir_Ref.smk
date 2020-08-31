"""
Authors:
    Dennis Schmitz, Sam Nooij, Florian Zwagemaker, Robert Verhagen,
    Jeroen Cremer, Thierry Janssens, Mark Kroon, Erwin van Wieringen,
    Annelies Kroneman, Harry Vennema, Marion Koopmans
Acknowledgement:
    Jeroen van Rooij, André Uitterlinden
Organization:
    Rijksinstituut voor Volksgezondheid en Milieu (RIVM)
    Dutch Public Health institute (https://www.rivm.nl/en)
Department:
    Virology - Emerging and Endemic Viruses (EEV)
    Virology - Viruses of the Vaccination Program (VVP)
    Bacteriology - Bacterial and Parasitic Diagnostics (BPD)
Date and license:
    19-12-2019, AGPL3 license
Description:
    Originally intended for the EAV internal control of the ENNGS ringtrail,
    later adapted for the nCoV outbreak. It's a WORK IN PROGRESS. It was
    initially intended for a coarse estimation of the BoC at different
    coverage thresholds.
Homepage containing documentation, examples and a changelog:
    https://github.com/DennisSchmitz/Jovian
Funding:
    This project/research has received funding from the European Union’s
    Horizon 2020 research and innovation programme under grant agreement
    No. 643476. and the Dutch working group on molecular diagnostics (WMDI).
Automation:
    iRODS automatically executes this workflow for all "vir-ngs" labelled
    Illumina sequencing runs. See the internal Gitlab repo for the wrapper
    with additional information.
    #TODO see below
    N.B. this is currently a hacky implementation, it automatically assumes
    samples are nCoV. Which is true for now but must be solved more elegantly
    at a later time.
    #TODO see above
"""

#@################################################################################
#@#### Import config file, sample_sheet and set output folder names          #####
#@################################################################################


shell.executable("/bin/bash")

# Load libraries
import pprint
import os
import yaml
yaml.warnings({'YAMLLoadWarning': False}) # Suppress yaml "unsafe" warnings.

from globals import *

configfile: f"{cnf}pipeline_parameters.yaml"
configfile: f"{cnf}variables.yaml"


# Import sample sheet
SAMPLES     =   {}
with open(config["sample_sheet"]) as sample_sheet_file:
    SAMPLES =   yaml.load(sample_sheet_file) # SAMPLES is a dict with sample in the form sample > read number > file. E.g.: SAMPLES["sample_1"]["R1"] = "x_R1.gz"


reference           =   config["reference_file"]
reference_basename  =   os.path.splitext(os.path.basename(reference))[0]


#@################################################################################
#@#### Specify Jovian's final output:                                        #####
#@################################################################################


localrules: 
    all,
    Illumina_index_reference,
    Illumina_determine_BoC_at_diff_cov_thresholds,
    Illumina_concat_BoC_metrics,
    Illumina_HTML_IGVJs_variable_parts,
    Illumina_HTML_IGVJs_generate_final

rule all:
    input:
        expand( "{p}{sample}_{read}.fq",
                p       =   f"{datadir + cln}",
                sample  =   SAMPLES,
                read    =   [   'pR1',
                                'pR2',
                                'unpaired'
                                ]
                ), # Extract unmapped & paired reads AND unpaired from HuGo alignment; i.e. cleaned fastqs #TODO omschrijven naar betere smk syntax
        expand( "{p}{ref}{extension}",
                p           =   f"{datadir + it1 + refdir}",
                ref         =   reference_basename,
                extension   =   [   '.fasta',
                                    '.fasta.1.bt2'
                                    ]
                ), # Copy of the reference file (for standardization and easy logging), bowtie2-indices (I've only specified one, but the "2.bt2", "3.bt2", "4.bt2", "rev.1.bt2" and "rev.2.bt2" are implicitly generated) and the GC-content files.
                        expand( "{p}{ref}_{sample}{extension}",
                p           =   f"{datadir + it2 + refdir}",
                ref         =   reference_basename,
                sample      =   SAMPLES,
                extension   =   [   '.fasta',
                                    '.fasta.1.bt2',
                                    '.fasta.fai',
                                    '.fasta.sizes', 
                                    '.windows',
                                    '_GC.bedgraph'
                                    ]
                ), # Copy of the reference file (for standardization and easy logging), bowtie2-indices (I've only specified one, but the "2.bt2", "3.bt2", "4.bt2", "rev.1.bt2" and "rev.2.bt2" are implicitly generated) and the GC-content files.
        expand( "{p}{sample}_sorted.{extension}",
                p           =   f"{datadir + it1 + aln}",
                sample      =   SAMPLES,
                extension   =   [   'bam',
                                    'bam.bai',
                                    'MarkDup_metrics'
                                    ]
                ), # The reference alignment (bam format) files.
        expand( "{p}{sample}_sorted.{extension}",
                p           =   f"{datadir + it2 + aln}",
                sample      =   SAMPLES,
                extension   =   [   'bam',
                                    'bam.bai',
                                    'MarkDup_metrics'
                                    ]
                ), # The reference alignment (bam format) files.
        expand( "{p}{sample}{extension}",
                p           =   f"{datadir + it1 + cons + raw}",
                sample      =   SAMPLES,
                extension   =   [   '.vcf.gz', 
                                    '_raw_consensus.fa'
                                    ]
                ), # A zipped vcf file contained SNPs versus the given reference and a IlluminaW consensus sequence, see explanation below for the meaning of Illumina.
        expand( "{p}{sample}{extension}",
                p           =   f"{datadir + it2 + cons + raw}",
                sample      =   SAMPLES,
                extension   =   [   '.vcf.gz', 
                                    '_raw_consensus.fa'
                                    ]
                ), # A zipped vcf file contained SNPs versus the given reference and a IlluminaW consensus sequence, see explanation below for the meaning of Illumina.
        expand( "{p}{sample}.bedgraph",
                p       =   f"{datadir + it2 + cons}",
                sample  =   SAMPLES
                ), # Lists the coverage of the alignment against the reference in a bedgraph format, is used to determine the coverage mask files below.
        expand( "{p}{sample}_{filt_character}-filt_cov_ge_{thresholds}.fa",
                p               =   f"{res + seqs}",
                sample          =   SAMPLES,
                filt_character  =   [   'N',
                                        'minus'
                                        ],
                thresholds      =   [   '1',
                                        '5', 
                                        '10',
                                        '30',
                                        '100'
                                        ]
                ), # Consensus sequences filtered for different coverage thresholds (1, 5, 10, 30 and 100). For each threshold two files are generated, one where failed positioned are replaced with a N nucleotide and the other where its replaced with a minus character (gap).
        expand( "{p}{sample}_BoC{extension}",
                p           =   f"{datadir + boc}",
                sample      =   SAMPLES,
                extension   =   [   '_int.tsv',
                                    '_pct.tsv'
                                    ]
                ), # Output of the BoC analysis #TODO can probably removed after the concat rule is added.
        f"{res}SNPs.tsv",
        f"{res}BoC_int.tsv", # Integer BoC overview in .tsv format
        f"{res}BoC_pct.tsv", # Percentage BoC overview in .tsv format
        expand( "{p}{ref}_{sample}_{extension}",
                p           =   f"{datadir + it2 + refdir}",
                ref         =   reference_basename,
                sample      =   SAMPLES,
                extension   =   [   'ORF_AA.fa',
                                    'ORF_NT.fa',
                                    'annotation.gff',
                                    'annotation.gff.gz',
                                    'annotation.gff.gz.tbi'
                                    ]
                ), # Prodigal ORF prediction output, required for the IGVjs visualisation
        f"{res}igv.html", # IGVjs output html
        f"{res}multiqc.html" # MultiQC report


#@################################################################################
#@#### The `onstart` checker codeblock                                       #####
#@################################################################################

onstart:
    shell("""
        mkdir -p {res} 
        echo -e "\nLogging pipeline settings..."

        echo -e "\tGenerating methodological hash (fingerprint)..."
        echo -e "This is the link to the code used for this analysis:\thttps://github.com/DennisSchmitz/Jovian/tree/$(git log -n 1 --pretty=format:"%H")" > {res}/log_git.txt
        echo -e "This code with unique fingerprint $(git log -n1 --pretty=format:"%H") was committed by $(git log -n1 --pretty=format:"%an <%ae>") at $(git log -n1 --pretty=format:"%ad")" >> {res}/log_git.txt

        echo -e "\tGenerating full software list of current Conda environment (\"Jovian_master\")..."
        conda list > {res}/log_conda.txt

        echo -e "\tGenerating used databases log..."
        echo -e "==> User-specified background reference (default: Homo Sapiens NCBI GRch38 NO DECOY genome): <==\n$(ls -lah $(grep "    background_ref:" config/pipeline_parameters.yaml | cut -f 2 -d ":"))\n" > {res}log_db.txt
        echo -e "\n==> Virus-Host Interaction Database: <==\n$(ls -lah $(grep "    virusHostDB:" config/pipeline_parameters.yaml | cut -f 2 -d ":"))\n" >> {res}log_db.txt
        echo -e "\n==> Krona Taxonomy Database: <==\n$(ls -lah $(grep "    Krona_taxonomy:" config/pipeline_parameters.yaml | cut -f 2 -d ":"))\n" >> {res}log_db.txt
        echo -e "\n==> NCBI new_taxdump Database: <==\n$(ls -lah $(grep "    NCBI_new_taxdump_rankedlineage:" config/pipeline_parameters.yaml | cut -f 2 -d ":") $(grep "    NCBI_new_taxdump_host:" config/pipeline_parameters.yaml | cut -f 2 -d ":"))\n" >> {res}log_db.txt
        echo -e "\n==> NCBI Databases as specified in .ncbirc: <==\n$(ls -lah $(grep "BLASTDB=" .ncbirc | cut -f 2 -d "=" | tr "::" " "))\n" >> {res}log_db.txt
        
        echo -e "\tGenerating config file log..."
        rm -f {res}/log_config.txt
        for file in {cnf}*.yaml
        do
            echo -e "\n==> Contents of file \"${{file}}\": <==" >> {res}/log_config.txt
            cat ${{file}} >> {res}/log_config.txt
            echo -e "\n\n" >> {res}/log_config.txt
        done
    """)


#@################################################################################
#@#### Reference alignment extension processes                               #####
#@################################################################################

#! rules via include statements are shared between core workflow and Illumina workflow
#>############################################################################
#>#### Data quality control and cleaning                                 #####
#>############################################################################

include: f"{rls}QC_raw.smk"
include: f"{rls}CleanData.smk"
include: f"{rls}QC_clean.smk"

#>############################################################################
#>#### Removal of background host data                                   #####
#>############################################################################

include: f"{rls}BG_removal_1.smk"
include: f"{rls}BG_removal_2.smk"
include: f"{rls}BG_removal_3.smk"


###########! nuttig om contig metrics rule ook toe te voegen?


#>############################################################################
#>#### Process the reference                                             #####
#>############################################################################
include: f"{rls}ILM_Ref_index.smk"

# iteration 1
include: f"{rls}ILM_Ref_align_to_ref_it1.smk"
include: f"{rls}ILM_Ref_extract_raw_cons_it1.smk"

# iteration 2
include: f"{rls}ILM_Ref_align_to_ref_it2.smk"
include: f"{rls}ILM_Ref_extract_raw_cons_it2.smk"

# determine ORF and GC based on iteration 2
include: f"{rls}ILM_Ref_ORF_analysis.smk"
include: f"{rls}ILM_Ref_GC_content.smk"

include: f"{rls}ILM_Ref_extract_clean_cons.smk"

include: f"{rls}ILM_Ref_concat-snips.smk"

include: f"{rls}ILM_Ref_boc_covs.smk"
include: f"{rls}ILM_Ref_boc_mets.smk"

include: f"{rls}ILM_Ref_multiqc.smk"

include: f"{rls}ILM_Ref_igv_vars.smk"
include: f"{rls}ILM_Ref_igv_combi.smk"


#@################################################################################
#@#### These are the conditional cleanup rules                               #####
#@################################################################################


onsuccess:
    shell("""
        echo -e "\nCleaning up..."
        
        echo -e "\tRemoving temporary files..."
        if [ "{config[remove_temp]}" != "0" ]; then
            rm -rf {datadir}{html}   # Remove intermediate IGVjs html chunks.
            rm -rf {datadir}{cln}{hugo_no_rm}    # Remove HuGo alignment files
        else
            echo -e "\t\tYou chose to not remove temp files: the human genome alignment files are not removed."
        fi

        echo -e "\tCreating symlinks for the interactive genome viewer..."
        {bindir}{scrdir}set_symlink.sh

        echo -e "\tGenerating HTML index of log files..."
        tree -hD --dirsfirst -H "../logs" -L 2 -T "Logs overview" --noreport --charset utf-8 -P "*" -o {res}logfiles_index.html {logdir}

        echo -e "\tGenerating Snakemake report..."
        snakemake -s {bindir}Illumina_vir_Ref.smk --unlock --profile config
        snakemake -s {bindir}Illumina_vir_Ref.smk --report {res}snakemake_report.html --profile config

        echo -e "Finished"
    """)
