#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/EAGER2
========================================================================================
 EAGER2 Analysis Pipeline. Started 2018-06-05
 #### Homepage / Documentation
 https://github.com/nf-core/EAGER2
 #### Authors
 Alexander Peltzer apeltzer <alex.peltzer@gmail.com> - https://github.com/apeltzer>
 James A. Fellows Yates <jfy133@gmail.com> - https://github.com/jfy133
 Stephen Clayton <clayton@shh.mpg.de> - https://github.com/sc13-bioinf
----------------------------------------------------------------------------------------
*/


/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// Configurable variables
params.name = false
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
params.saveReference = false
params.multiqc_config = "$baseDir/conf/multiqc_config.yaml"
params.email = false
params.plaintext_email = false

multiqc_config = file(params.multiqc_config)
output_docs = file("$baseDir/docs/output.md")

// Validate inputs
if ( params.fasta ){
    fasta = file(params.fasta)
    if( !fasta.exists() ) exit 1, "Fasta file not found: ${params.fasta}"
}
//
// NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// If you want to use the above in a process, define the following:
//   input:
//   file fasta from fasta
//


// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

/*
 * Create a channel for input read files
 */
Channel
    .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line." }
    .into { ch_read_files_clip, ch_read_files_fastqc }


// Header log info
log.info "========================================="
log.info " nf-core/EAGER2 v${params.version}"
log.info "========================================="
def summary = [:]
summary['Run Name']     = custom_runName ?: workflow.runName
summary['Reads']        = params.reads
summary['Fasta Ref']    = params.fasta
summary['Data Type']    = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Max Memory']   = params.max_memory
summary['Max CPUs']     = params.max_cpus
summary['Max Time']     = params.max_time
summary['Output dir']   = params.outdir
summary['Working dir']  = workflow.workDir
summary['Container']    = workflow.container
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Script dir']     = workflow.projectDir
summary['Config Profile'] = workflow.profile
if(params.email) summary['E-mail Address'] = params.email
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="


// Check that Nextflow version is up to date enough
// try / throw / catch works for NF versions < 0.25 when this was implemented
try {
    if( ! nextflow.version.matches(">= $params.nf_required_version") ){
        throw GroovyException('Nextflow version too old')
    }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version $params.nf_required_version required! You are running v$workflow.nextflow.version.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please run `nextflow self-update` to update Nextflow.\n" +
              "============================================================"
}


/*
 * Parse software version numbers: TODO testing this
 */
process get_software_versions {

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml

    script:
    """
    echo $params.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    echo \$(bwa 2>&1) > v_bwa.txt
    samtools --version > v_samtools.txt
    AdapterRemoval -version > v_adapterremoval.txt
    echo \$(ClipAndMerge 2>&1) v_clipandmerge.txt
    picard MarkDuplicates --version &> v_markduplicates.txt  || true
    dedup -h > v_dedup.txt
    #angsd > v_angsd.txt
    #realignsamfile > v_circularmapper.txt
    #schmutzi > v_schmutzi.txt
    gatk --version > v_gatk.txt
    qualimap --version > v_qualimap.txt
    vcf2genome > v_vcf2genome.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py > software_versions_mqc.yaml
    """
}

/* 
* Create BWA indices if they are not present
*/ 

if(!params.bwa_index && params.fasta && params.aligner == 'bwa'){
    process makeBWAIndex {
        tag fasta
        publishDir path: "${params.outdir}/reference_genome", saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file fasta from fasta

        output:
        file "${fasta}*" into ch_bwa_indices

        script:
        """
        bwa index $fasta
        """
    }
}

/*
 * PREPROCESSING - Index Fasta file
 */
if(!params.fasta_index && params.fasta && params.aligner == 'bwa'){
    process makeFastaIndex {
        tag fasta
        publishDir path: "${params.outdir}/reference_genome", saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file fasta

        output:
        file "${fasta}.fai" into ch_fasta_index

        script:
        """
        samtools faidx $fasta
        """
    }
}

/*
 * PREPROCESSING - Create Sequence Dictionary for FastA
 */
if(!params.seq_dict && params.fasta){
    process makeSeqDict {
        tag seqdict
        publishDir path: "${params.outdir}/reference_genome", saveAs: { params.saveReference ? it : null }, mode: 'copy'

        input:
        file fasta

        output:
        file "${fasta}.dict" into ch_seq_dict

        script:
        """
        picard CreateSequenceDictionary R=$fasta O= $fasta.dict
        """
    }
}


/*
 * STEP 1 - FastQC
 */
process fastqc {
    tag "$name"
    publishDir "${params.outdir}/01-FastQC", mode: 'copy',
        saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

    input:
    set val(name), file(reads) from ch_read_files_fastqc

    output:
    file "*_fastqc.{zip,html}" into ch_fastqc_results

    script:
    """
    fastqc -q $reads
    """
}

/*
 * STEP 2 - Adapter Clipping / Read Merging
 */

if(params.mergemethod == 'AdapterRemoval'){

process adapter_removal {
    tag "$name"
    publishDir "${params.outdir}/02-Merging", mode: 'copy'

    input:
    set val(name), file(reads) from ch_read_files_clip

    output:
    file "*.combined.fq.gz" into ch_clipped_reads

    script:
    prefix = reads[0].toString() - ~/(_R1)?(_trimmed)?(_val_1)?(\.fq)?(\.fastq)?(\.gz)?$/
    """
    AdapterRemoval --file1 ${reads[0]} --file2 ${reads[1]} --baseName ${prefix} --gzip --threads ${process.cpus} --trimns --trimqualities --adapter1 ${params.clip.forward_adaptor} --adapter2 ${params.clip.reverse_adaptor} --minlength ${params.clip.readlength} --minquality ${params.clip.min_read_quality} --minadapteroverlap ${params.min_adap_overlap} --collapse
    #Fix Prefixes
    AdapterRemovalFixPrefix  TODO
    #Combine files
    zcat *.collapsed.gz *.collapsed.truncated.gz *.singleton.truncated.gz *.pair1.truncated.gz *.pair2.truncated.gz | gzip > ${prefix}.combined.fq.gz
    """


} else { //We use Clip&Merge then
process clip_merge {
    tag "$name"
    publishDir "${params.outdir}/02-Merging", mode: 'copy'

    input:
    set val(name), file(reads) from ch_read_files_clip

    output:
    file "*.fastq.gz" into ch_clipped_reads

    script:
    """
    ClipAndMerge -in1 ${reads[0]} -in2 ${reads[1]}
    -f ${params.clip.forward_adaptor} -r ${params.clip.reverse_adaptor}
    -trim3p ${params.clip.3pclip} -trim5p ${params.clip.5pclip} -l ${params.clip.readlength} -m ${params.clip.min_adap_overlap} -qt -q ${params.clip.min_read_quality} -log "ClipAndMergeStats.log"
    """
}}

if(params.mergemethod == 'AdapterRemoval'){
  process adapter_removal_fixprefix {
      tag "$name"
      publishDir "${params.outdir}/02-Merging", mode: 'copy'

      input:
      set val(name), file(reads) from ch_clipped_reads

      output:
      file "*.fastq.prefixed.gz" into ch_mappable_reads

      script:
      '''
      AdapterRemovalFixPrefix ${reads} ${reads}.fastq.prefixed.gz
      '''
  }
} else { //Don't do something with the reads
    ch_mappable_reads = ch_clipped_reads
}


/*
Step 3: Mapping with BWA, CircularMapper
Step 4: Conversion to BAM; sorting
Step 5: Keep unmapped/remove unmapped reads
Step 5.1: Preseq
Step 5.2: DMG Assessment
Step 5.3: Qualimap (before or after Dedup?)
Step 6: DeDup / MarkDuplicates
Step 7: angsd
Step 7: GATK
Step 8: vcf2genome

*/


/*
 * STEP 2 - MultiQC
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config
    file ('fastqc/*') from fastqc_results.collect()
    file ('software_versions/*') from software_versions_yaml

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config .
    """
}



/*
 * STEP 3 - Output Description HTML
 */
process output_documentation {
    tag "$prefix"
    publishDir "${params.outdir}/Documentation", mode: 'copy'

    input:
    file output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}



/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/EAGER2] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/EAGER2] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = params.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['software_versions'] = software_versions
    email_fields['software_versions']['Nextflow Build'] = workflow.nextflow.build
    email_fields['software_versions']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir" ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/EAGER2] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/EAGER2] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/Documentation/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    log.info "[nf-core/EAGER2] Pipeline Complete"
}

/**
Useful functionality, e.g. help messages etc
* 
*/ 


def helpMessage() {
    log.info"""
    =========================================
    EAGER2 v${params.version}
    =========================================
    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/EAGER2 --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      --genome                      Name of iGenomes reference
      -profile                      Hardware config to use. docker / aws

    Options:
      --singleEnd                   Specifies that the input is single end reads

    References                      If not specified in the configuration file or you wish to overwrite any of the references.
      --fasta                       Path to Fasta reference
      --bwa_index                   Path to BWA index

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
    """.stripIndent()
}
