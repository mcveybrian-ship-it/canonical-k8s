# ASD STIG — answers

**THIS FILE IS HAND-WRITTEN.** It is the only part of the ASD work a person writes,
and re-running `asd-triage.py` **merges rather than overwrites** — answers survive.

Replace every `« … »` with a statement of fact about this system. Completion check:

```bash
grep -c '«' docs/compliance/asd-answers.md     # 0 means finished
```

> **Write a FACT, not a verdict.** *"There is no locally developed application; this
> enclave hosts vendor products only"* is evidence. *"N/A"* is not. Each checklist row
> is then composed from your fact PLUS DISA's own sentence quoted verbatim — which is
> what makes 139 near-identical rows defensible rather than repetitive.

**Progress: 1 of 82 answered.**

---

## Part 1 — properties the STIG asks about

81 questions covering 139 rules that carry their own N/A clause.

<!-- id:prop:application-is-configured-to-use-enterprisebased-a -->
### application is configured to use enterprisebased application — 12 rules

> If the application is configured to use an enterprise-based application user management capability that is STIG compliant, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>12 rules</summary>

- `V-222411` APSC-DV-000320 — The application must automatically disable accounts after a 35 day period of account inactivity
- `V-222413` APSC-DV-000340 — The application must automatically audit account creation.
- `V-222414` APSC-DV-000350 — The application must automatically audit account modification.
- `V-222415` APSC-DV-000360 — The application must automatically audit account disabling actions.
- `V-222416` APSC-DV-000370 — The application must automatically audit account removal actions.
- `V-222417` APSC-DV-000380 — The application must notify system administrators (SAs) and information system security officer
- `V-222418` APSC-DV-000390 — The application must notify system administrators (SAs) and information system security officer
- `V-222419` APSC-DV-000400 — The application must notify system administrators (SAs) and information system security officer
- `V-222420` APSC-DV-000410 — The application must notify system administrators (SAs) and information system security officer
- `V-222421` APSC-DV-000420 — The application must automatically audit account enabling actions.
- `V-222422` APSC-DV-000430 — The application must notify system administrators (SAs) and information system security officer
- `V-222467` APSC-DV-000880 — The application must generate audit records for all account creations, modifications, disabling

</details>

<!-- id:prop:passwords -->
### passwords — 12 rules, **3 CAT I**

> If the application does not use passwords, this requirement is Not Applicable.

**Answer:** « state the fact about this system »

<details><summary>12 rules</summary>

- `V-222536` APSC-DV-001680 — The application must enforce a minimum 15-character password length.
- `V-222537` APSC-DV-001690 — The application must enforce password complexity by requiring that at least one uppercase chara
- `V-222538` APSC-DV-001700 — The application must enforce password complexity by requiring that at least one lowercase chara
- `V-222539` APSC-DV-001710 — The application must enforce password complexity by requiring that at least one numeric charact
- `V-222540` APSC-DV-001720 — The application must enforce password complexity by requiring that at least one special charact
- `V-222541` APSC-DV-001730 — The application must require the change of at least eight of the total number of characters whe
- `V-222542` APSC-DV-001740 — The application must only store cryptographic representations of passwords.
- `V-222543` APSC-DV-001750 — The application must transmit only cryptographically-protected passwords.
- `V-222544` APSC-DV-001760 — The application must enforce 24 hours/1 day as the minimum password lifetime.
- `V-222545` APSC-DV-001770 — The application must enforce a 60-day maximum password lifetime restriction.
- `V-222546` APSC-DV-001780 — The application must prohibit password reuse for a minimum of five generations.
- `V-222547` APSC-DV-001790 — The application must allow the use of a temporary password for system logons with an immediate 

</details>

<!-- id:prop:saml-assertions -->
### saml assertions — 6 rules, **2 CAT I**

> If the application does not utilize SAML assertions, this check is not applicable.

**Answer:** « state the fact about this system »

<details><summary>6 rules</summary>

- `V-222401` APSC-DV-000210 — The application must ensure each unique asserting party provides unique assertion ID references
- `V-222403` APSC-DV-000230 — The application must use the NotOnOrAfter condition when using the SubjectConfirmation element 
- `V-222404` APSC-DV-000240 — The application must use both the NotBefore and NotOnOrAfter elements or OneTimeUse element whe
- `V-222405` APSC-DV-000250 — The application must ensure if a OneTimeUse element is used in an assertion, there is only one 
- `V-222406` APSC-DV-000260 — The application must ensure messages are encrypted when the SessionIndex is tied to privacy dat
- `V-222573` APSC-DV-002050 — Applications making SAML assertions must use FIPS-approved random numbers in the generation of 

</details>

<!-- id:prop:nonlocal-maintenance-and-diagnostic-capability -->
### nonlocal maintenance and diagnostic capability — 6 rules

> If the application does not provide non-local maintenance and diagnostic capability, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>6 rules</summary>

- `V-222561` APSC-DV-001930 — Applications used for non-local maintenance sessions must audit non-local maintenance and diagn
- `V-222562` APSC-DV-001940 — Applications used for non-local maintenance sessions must implement cryptographic mechanisms to
- `V-222563` APSC-DV-001950 — Applications used for non-local maintenance sessions must implement cryptographic mechanisms to
- `V-222564` APSC-DV-001960 — Applications used for non-local maintenance sessions must verify remote disconnection at the te
- `V-222565` APSC-DV-001970 — The application must employ strong authenticators in the establishment of non-local maintenance
- `V-222566` APSC-DV-001980 — The application must terminate all sessions and network connections when nonlocal maintenance i

</details>

<!-- id:prop:application-utilizes-centralized-logging-system-th -->
### application utilizes centralized logging system that provide — 5 rules

> If the application utilizes a centralized logging system that provides the audit processing failure alarms, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>5 rules</summary>

- `V-222485` APSC-DV-001110 — The application must alert the ISSO and SA (at a minimum) in the event of an audit processing f
- `V-222487` APSC-DV-001130 — The application must provide the capability to centrally review and analyze audit records from 
- `V-222488` APSC-DV-001140 — The application must provide the capability to filter audit records for events of interest base
- `V-222489` APSC-DV-001150 — The application must provide an audit reduction capability that supports on-demand reporting re
- `V-222490` APSC-DV-001160 — The application must provide an audit reduction capability that supports on-demand audit review

</details>

<!-- id:prop:pki-enabled-due-to-hosted-data-being-publicly-rele -->
### pki enabled due to hosted data being publicly releasable — 5 rules

> If the application is not PK-enabled due to the hosted data being publicly releasable, this check is not applicable.

**Answer:** « state the fact about this system »

<details><summary>5 rules</summary>

- `V-222524` APSC-DV-001560 — The application must accept Personal Identity Verification (PIV) credentials.
- `V-222525` APSC-DV-001570 — The application must electronically verify Personal Identity Verification (PIV) credentials.
- `V-222526` APSC-DV-001580 — The application must use multifactor (e.g., CAC, Alt. Token) authentication for network access 
- `V-222557` APSC-DV-001880 — The application must accept Personal Identity Verification (PIV) credentials from other federal
- `V-222558` APSC-DV-001890 — The application must electronically verify Personal Identity Verification (PIV) credentials fro

</details>

<!-- id:prop:application-requirements-do-not-call-for-compartme -->
### application requirements do not call for compartmentalized d — 3 rules

> If the application requirements do not call for compartmentalized data and data protection, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>3 rules</summary>

- `V-222453` APSC-DV-000740 — The application must generate audit records when successful/unsuccessful attempts to access cat
- `V-222457` APSC-DV-000780 — The application must generate audit records when successful/unsuccessful attempts to modify cat
- `V-222461` APSC-DV-000820 — The application must generate audit records when successful/unsuccessful attempts to delete cat

</details>

<!-- id:prop:application-uses-centralized-logging-solution-that -->
### application uses centralized logging solution that performs  — 3 rules

> If the application uses a centralized logging solution that performs the audit reduction (event filtering) functions, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>3 rules</summary>

- `V-222491` APSC-DV-001170 — The application must provide an audit reduction capability that supports after-the-fact investi
- `V-222494` APSC-DV-001200 — The application must provide a report generation capability that supports after-the-fact invest
- `V-222495` APSC-DV-001210 — The application must provide an audit reduction capability that does not alter original content

</details>

<!-- id:prop:application-does-not-provide-distinct-audit-tool-o -->
### application does not provide distinct audit tool oriented fu — 3 rules

> If the application does not provide a distinct audit tool oriented functionality that is a separate tool with an ability to view and manipulate log data, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>3 rules</summary>

- `V-222503` APSC-DV-001310 — The application must protect audit tools from unauthorized access.
- `V-222504` APSC-DV-001320 — The application must protect audit tools from unauthorized modification.
- `V-222505` APSC-DV-001330 — The application must protect audit tools from unauthorized deletion.

</details>

<!-- id:prop:pkienabled-due-to-hosted-data-being-publicly-relea -->
### pkienabled due to hosted data being publicly releasable — 3 rules

> If the application is not PKI-enabled due to the hosted data being publicly releasable, this check is Not Applicable.

**Answer:** « state the fact about this system »

<details><summary>3 rules</summary>

- `V-222528` APSC-DV-001600 — The application must use multifactor (e.g., CAC, Alt. Token) authentication for local access to
- `V-222559` APSC-DV-001900 — The application must accept Federal Identity, Credential, and Access Management (FICAM)-approve
- `V-222560` APSC-DV-001910 — The application must conform to Federal Identity, Credential, and Access Management (FICAM)-iss

</details>

<!-- id:prop:designed-or-intended-to-perform-security-function- -->
### designed or intended to perform security function testing — 3 rules

> If the application is not designed or intended to perform security function testing, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>3 rules</summary>

- `V-222615` APSC-DV-002760 — The application performing organization-defined security functions must verify correct operatio
- `V-222616` APSC-DV-002770 — The application must perform verification of the correct operation of security functions: upon 
- `V-222617` APSC-DV-002780 — The application must notify the ISSO and ISSM of failed security verification tests.

</details>

<!-- id:prop:interface-for-interactive-user-access -->
### interface for interactive user access — 2 rules

> If the application does not provide an interface for interactive user access, this is not applicable.

**Answer:** « state the fact about this system »

<details><summary>2 rules</summary>

- `V-222391` APSC-DV-000090 — Applications requiring user access authentication must provide a logoff capability for user ini
- `V-222392` APSC-DV-000100 — The application must display an explicit logoff message to users indicating the reliable termin

</details>

<!-- id:prop:wssecurity-tokens -->
### wssecurity tokens — 2 rules, **1 CAT I**

> If the application does not utilize WS-Security tokens, this check is not applicable.

**Answer:** « state the fact about this system »

<details><summary>2 rules</summary>

- `V-222399` APSC-DV-000190 — Messages protected with WS_Security must use time stamps with creation and expiration times.
- `V-222402` APSC-DV-000220 — The application must ensure encrypted assertions, or equivalent confidentiality protections are

</details>

<!-- id:prop:data-flow-control-capabilities -->
### data flow control capabilities — 2 rules

> If the application does not provide data flow control capabilities, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>2 rules</summary>

- `V-222427` APSC-DV-000480 — The application must enforce approved authorizations for controlling the flow of information wi
- `V-222428` APSC-DV-000490 — The application must enforce approved authorizations for controlling the flow of information be

</details>

<!-- id:prop:application-has-no-interactive-user-interface -->
### application has no interactive user interface — 2 rules

> If the application has no interactive user interface, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>2 rules</summary>

- `V-222434` APSC-DV-000550 — The application must display the Standard Mandatory DoD Notice and Consent Banner before granti
- `V-222435` APSC-DV-000560 — The application must retain the Standard Mandatory DoD Notice and Consent Banner on the screen 

</details>

<!-- id:prop:application-uses-centralized-logging-solution-that -->
### application uses centralized logging solution that provides  — 2 rules

> If the application uses a centralized logging solution that provides immediate, customizable audit review and analysis functions, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>2 rules</summary>

- `V-222492` APSC-DV-001180 — The application must provide a report generation capability that supports on-demand audit revie
- `V-222493` APSC-DV-001190 — The application must provide a report generation capability that supports on-demand reporting r

</details>

<!-- id:prop:application-does-not-provide-separate-tool-in-form -->
### application does not provide separate tool in form of file w — 2 rules

> If the application does not provide a separate tool in the form of a file which provides an ability to view and manipulate application log data, query data, or generate reports, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>2 rules</summary>

- `V-222508` APSC-DV-001360 — Application audit tools must be cryptographically hashed.
- `V-222509` APSC-DV-001370 — The integrity of the audit tools must be validated by checking the files for changes in the cry

</details>

<!-- id:prop:application-is-hosting-publicly-releasable-informa -->
### application is hosting publicly releasable information that  — 2 rules

> If the application is hosting publicly releasable information that does not require authentication, or if the application users are not eligible for a DoD CAC as per DoD 8520, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>2 rules</summary>

- `V-222530` APSC-DV-001620 — The application must implement replay-resistant authentication mechanisms for network access to
- `V-222531` APSC-DV-001630 — The application must implement replay-resistant authentication mechanisms for network access to

</details>

<!-- id:prop:application-development-is-not-done-in-house-and-i -->
### application development is not done in house and if code con — 2 rules

> If application development is not done in house and if a code configuration management repository does not exist, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>2 rules</summary>

- `V-222631` APSC-DV-003000 — Access privileges to the Configuration Management (CM) repository must be reviewed every three 
- `V-222632` APSC-DV-003010 — A Software Configuration Management (SCM) plan describing the configuration control and change 

</details>

<!-- id:prop:classified-cui-or-other-data-that-is-required-to-b -->
### classified cui or other data that is required to be marked — 1 rules

> If the application does not contain classified, CUI, or other data that is required to be marked, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222393` APSC-DV-000110 — The application must associate organization-defined types of security attributes having organiz

</details>

<!-- id:prop:classified-or-cui-data-or-have-data-marking-requir -->
### classified or cui data or have data marking requirements — 1 rules

> If the application does not contain classified or CUI data or have data marking requirements, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222394` APSC-DV-000120 — The application must associate organization-defined types of security attributes having organiz

</details>

<!-- id:prop:transmit-data -->
### transmit data — 1 rules

> If the application does not contain classified or CUI data or have data marking requirements, or if the application does not transmit data, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222395` APSC-DV-000130 — The application must associate organization-defined types of security attributes having organiz

</details>

<!-- id:prop:soap-messages -->
### soap messages — 1 rules

> If the application does not utilize SOAP messages, this check is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222398` APSC-DV-000180 — Applications with SOAP messages requiring integrity must include the following message elements

</details>

<!-- id:prop:wss-or-saml-assertions -->
### wss or saml assertions — 1 rules, **1 CAT I**

> If the application does not utilize WSS or SAML assertions, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222400` APSC-DV-000200 — Validity periods must be verified on all application messages using WS-Security or SAML asserti

</details>

<!-- id:prop:there-is-no-official-requirement-for-shared-or-gro -->
### there is no official requirement for shared or group applica — 1 rules

> If there is no official requirement for shared or group application accounts, this requirement is Not Applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222408` APSC-DV-000290 — Shared/group account credentials must be terminated when members leave the group.

</details>

<!-- id:prop:official-documentation-exist-that-disallows-use-of -->
### official documentation exist that disallows use of temporary — 1 rules

> If official documentation exist that disallows the use of temporary user accounts within the application, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222409` APSC-DV-000300 — The application must automatically remove or disable temporary user accounts 72 hours after acc

</details>

<!-- id:prop:emergency-accounts-are-not-used -->
### emergency accounts are not used — 1 rules

> If emergency accounts are not used, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222410` APSC-DV-000310 — The application must have a process, feature or function that prevents removal or disabling of 

</details>

<!-- id:prop:there-are-no-data-mining-protections-required -->
### there are no data mining protections required — 1 rules

> If there are no data mining protections required, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222424` APSC-DV-000450 — The application must utilize organization-defined data mining detection techniques for organiza

</details>

<!-- id:prop:discretionary-access-controls -->
### discretionary access controls — 1 rules

> If the application does not implement discretionary access controls, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222426` APSC-DV-000470 — The application must enforce organization-defined discretionary access control policies over de

</details>

<!-- id:prop:publicly-accessible -->
### publicly accessible — 1 rules

> If the application is not publicly accessible, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222436` APSC-DV-000570 — The publicly accessible application must display the Standard Mandatory DoD Notice and Consent 

</details>

<!-- id:prop:user-interface -->
### user interface — 1 rules

> If the application does not provide a user interface, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222437` APSC-DV-000580 — The application must display the time and date of the users last successful logon.

</details>

<!-- id:prop:application-documentation-specifically-states-that -->
### application documentation specifically states that nonrepudi — 1 rules

> If the application documentation specifically states that non-repudiation services for application users are not defined as part of the application design, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222438` APSC-DV-000590 — The application must protect against an individual (or process acting on behalf of an individua

</details>

<!-- id:prop:log-aggregation-services -->
### log aggregation services — 1 rules

> If the application does not provide log aggregation services, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222439` APSC-DV-000600 — For applications providing audit record aggregation, the application must compile audit records

</details>

<!-- id:prop:direct-access-to-system -->
### direct access to system — 1 rules

> If the application does not provide direct access to the system, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222466` APSC-DV-000870 — The application must generate audit records for all direct access to the information system.

</details>

<!-- id:prop:initiate-connections-to-remote-systems -->
### initiate connections to remote systems — 1 rules

> If the application design documentation indicates the application does not initiate connections to remote systems this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222470` APSC-DV-000950 — The application must log destination IP addresses.

</details>

<!-- id:prop:logging-locally-and-does-not-utilize-centralized-l -->
### logging locally and does not utilize centralized logging sol — 1 rules

> If the application is logging locally and does not utilize a centralized logging solution, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222475` APSC-DV-001000 — When using centralized logging; the application must include a unique identifier in order to di

</details>

<!-- id:prop:application-is-configured-to-log-application-event -->
### application is configured to log application event entries t — 1 rules

> If the application is configured to log application event entries to a centralized, enterprise based logging solution that meets this requirement, this requirement is Not Applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222480` APSC-DV-001050 — The application must provide centralized management and configuration of the content to be capt

</details>

<!-- id:prop:configured-to-utilize-centralized-logging-solution -->
### configured to utilize centralized logging solution — 1 rules

> If the application is configured to utilize a centralized logging solution, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222481` APSC-DV-001070 — The application must off-load audit records onto a different system or media than the system be

</details>

<!-- id:prop:centralized-logging-system-that-provides-storage-c -->
### centralized logging system that provides storage capacity al — 1 rules

> If the application utilizes a centralized logging system that provides storage capacity alarming, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222483` APSC-DV-001090 — The application must provide an immediate warning to the SA and ISSO (at a minimum) when alloca

</details>

<!-- id:prop:centralized-logging-system-that-provides-realtime- -->
### centralized logging system that provides realtime alarms — 1 rules

> If the application utilizes a centralized logging system that provides the real-time alarms, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222484` APSC-DV-001100 — Applications categorized as having a moderate or high impact must provide an immediate real-tim

</details>

<!-- id:prop:report-generation-capability -->
### report generation capability — 1 rules

> If the application does not provide a report generation capability, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222496` APSC-DV-001220 — The application must provide a report generation capability that does not alter original conten

</details>

<!-- id:prop:application-utilizes-underlying-os-for-time-stampi -->
### application utilizes underlying os for time stamping and tim — 1 rules

> If the application utilizes the underlying OS for time stamping and time synchronization when writing the audit logs, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222499` APSC-DV-001270 — The application must record time stamps for audit records that meet a granularity of one second

</details>

<!-- id:prop:application-does-not-include-builtin-backup-capabi -->
### application does not include builtin backup capability for b — 1 rules

> If the application does not include a built-in backup capability for backing up its own audit records, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222506` APSC-DV-001340 — The application must back up audit records at least every seven days onto a different system or

</details>

<!-- id:prop:application-is-configured-to-utilize-centralized-a -->
### application is configured to utilize centralized audit log s — 1 rules

> If the application is configured to utilize a centralized audit log solution that uses cryptographic methods that meet this requirement such as creating cryptographic hash values or message digests that can be used to validate integrity of audit files, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222507` APSC-DV-001350 — The application must use cryptographic mechanisms to protect the integrity of audit information

</details>

<!-- id:prop:application-does-not-provide-ability-to-install-so -->
### application does not provide ability to install software com — 1 rules

> If the application does not provide the ability to install software components, modules, plugins, or extensions, the requirement is Not Applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222510` APSC-DV-001390 — The application must prohibit user installation of software without explicit privileged status.

</details>

<!-- id:prop:policy-terms-or-conditions-state-there-are-no-usag -->
### policy terms or conditions state there are no usage restrict — 1 rules

> If the policy, terms, or conditions state there are no usage restrictions, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222516` APSC-DV-001480 — The application must prevent program execution in accordance with organization-defined policies

</details>

<!-- id:prop:application-is-not-configuration-management-or-sim -->
### application is not configuration management or similar type  — 1 rules

> If the application is not a configuration management or similar type of application designed to manage system processes and configurations, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222517` APSC-DV-001490 — The application must employ a deny-all, permit-by-exception (whitelist) policy to allow the exe

</details>

<!-- id:prop:retirees-or-members-of-public-with-no-requirement- -->
### retirees or members of public with no requirement for dod cr — 1 rules, **1 CAT I**

> , retirees) or members of the public with no requirement for DoD credentials, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222522` APSC-DV-001540 — The application must uniquely identify and authenticate organizational users (or processes acti

</details>

<!-- id:prop:group-or-shared-accounts -->
### group or shared accounts — 1 rules

> If the application does not use group or shared accounts, this requirement is Not Applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222529` APSC-DV-001610 — The application must ensure users are authenticated with an individual authenticator prior to u

</details>

<!-- id:prop:application-is-designed-to-provide-enduser-interac -->
### application is designed to provide enduser interactive appli — 1 rules

> If the application is designed to provide end-user, interactive application access only and does not use web services or allow connections from remote devices, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222533` APSC-DV-001650 — The application must authenticate all network connected endpoint devices before establishing an

</details>

<!-- id:prop:application-is-not-designed-to-authenticate-device -->
### application is not designed to authenticate devices such as  — 1 rules

> If the application is not designed to authenticate devices (such as mobile phones, gateways or other smart devices), or uses DOD PKI certificates to authenticate these devices, this requirement is Not Applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222535` APSC-DV-001670 — The application must disable device identifiers after 35 days of inactivity unless a cryptograp

</details>

<!-- id:prop:application-does-not-perform-code-signing-or-other -->
### application does not perform code signing or other cryptogra — 1 rules, **1 CAT I**

> If the application does not perform code signing or other cryptographic tasks requiring a private key, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222551` APSC-DV-001820 — The application, when using PKI-based authentication, must enforce authorized access to the cor

</details>

<!-- id:prop:application-resides-on-siprnet-and-does-not-have-a -->
### application resides on siprnet and does not have access to r — 1 rules

> If the application resides on the SIPRnet and does not have access to the root CAs, this requirement is Not Applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222553` APSC-DV-001840 — The application, for PKI-based authentication, must implement a local cache of revocation data 

</details>

<!-- id:prop:authenticated-access-to-cryptographic-module -->
### authenticated access to cryptographic module — 1 rules, **1 CAT I**

> If the application does not provide authenticated access to a cryptographic module, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222555` APSC-DV-001860 — The application must use mechanisms meeting the requirements of applicable federal laws, Execut

</details>

<!-- id:prop:host-nonorganizational-users -->
### host nonorganizational users — 1 rules

> If the application does not host non-organizational users, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222556` APSC-DV-001870 — The application must uniquely identify and authenticate non-organizational users (or processes 

</details>

<!-- id:prop:data-is-strictly-publicly-releasable-information-a -->
### data is strictly publicly releasable information and system  — 1 rules, **1 CAT I**

> If the data is strictly publicly releasable information and system documentation specifies no data encryption is required for any hosted application data, this is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222588` APSC-DV-002340 — The application must implement approved cryptographic mechanisms to prevent unauthorized modifi

</details>

<!-- id:prop:data-is-strictly-publicly-releasable-information-w -->
### data is strictly publicly releasable information with no sbu — 1 rules, **1 CAT I**

> If the data is strictly publicly releasable information with no SBU, CUI, or classified and system documentation specifies no data encryption is required for any hosted application data, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222589` APSC-DV-002350 — The application must use appropriate cryptography in order to protect stored DOD information wh

</details>

<!-- id:prop:or-utilize-xml -->
### or utilize xml — 1 rules

> If the application does not contain or utilize XML, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222593` APSC-DV-002390 — XML-based applications must mitigate DoS attacks by using XML filters, parser options, or gatew

</details>

<!-- id:prop:application-has-not-been-designated-as-high-availa -->
### application has not been designated as high availability sys — 1 rules

> If the application has not been designated as a high availability system, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222595` APSC-DV-002410 — The web service design must include redundancy mechanisms when used with high-availability syst

</details>

<!-- id:prop:process-xml -->
### process xml — 1 rules, **1 CAT I**

> If the application does not process XML, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222608` APSC-DV-002550 — The application must not be vulnerable to XML-oriented attacks.

</details>

<!-- id:prop:application-does-not-contain-mobile-code-or-if-mob -->
### application does not contain mobile code or if mobile code e — 1 rules

> If the application does not contain mobile code, or if the mobile code executes within the client browser, this is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222618` APSC-DV-002870 — Unsigned Category 1A mobile code must not be used in the application in accordance with DoD pol

</details>

<!-- id:prop:hosted-in-dod-dmz -->
### hosted in dod dmz — 1 rules, **1 CAT I**

> If the application is not hosted in the DoD DMZ, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222620` APSC-DV-002890 — Application web servers must be on a separate network segment from the application and database

</details>

<!-- id:prop:deploy-web-services -->
### deploy web services — 1 rules

> If the application does not deploy web services, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222625` APSC-DV-002950 — Execution flow diagrams and design documents must be created to show how deadlock and recursion

</details>

<!-- id:prop:this-is-not-case-requirement-is -->
### this is not case requirement is — 1 rules

> If this is not the case, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222630` APSC-DV-002995 — The Configuration Management (CM) repository must be properly patched and STIG compliant.

</details>

<!-- id:prop:application-development-is-not-done-in-house-requi -->
### application development is not done in house requirement is — 1 rules

> If application development is not done in house, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222633` APSC-DV-003020 — A Configuration Control Board (CCB) that meets at least every release cycle, for managing the C

</details>

<!-- id:prop:key-exchange -->
### key exchange — 1 rules

> If the application does not implement key exchange, this check is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222641` APSC-DV-003100 — The application must use encryption to implement key exchange and authenticate endpoints prior 

</details>

<!-- id:prop:review-is-not-being-done-with-developer-of-applica -->
### review is not being done with developer of application — 1 rules

> If the review is not being done with the developer of the application, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222644` APSC-DV-003130 — Prior to each release of the application, updates to system, or applying patches; tests plans a

</details>

<!-- id:prop:doing-development-work -->
### doing development work — 1 rules

> If the organization operating the application is not doing development work, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222646` APSC-DV-003150 — At least one tester must be designated to test for security flaws in addition to functional tes

</details>

<!-- id:prop:otherwise-requirement-is -->
### otherwise requirement is — 1 rules

> Otherwise, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222648` APSC-DV-003170 — An application code review must be performed on the application.

</details>

<!-- id:prop:organization-does-not-do-or-manage-application-dev -->
### organization does not do or manage application development w — 1 rules

> If the organization does not do or manage the application development work for the application, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222649` APSC-DV-003180 — Code coverage statistics must be maintained for each release of the application.

</details>

<!-- id:prop:application-development-is-not-being-done-or-manag -->
### application development is not being done or managed by orga — 1 rules

> If application development is not being done or managed by the organization, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222650` APSC-DV-003190 — Flaws found during a code review must be tracked in a defect tracking system.

</details>

<!-- id:prop:performing-or-managing-development-of-application -->
### performing or managing development of application — 1 rules

> If the organization managing the application is not performing or managing the development of the application the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222652` APSC-DV-003210 — Security flaws must be fixed or addressed in the project plan.

</details>

<!-- id:prop:organization-operating-application-under-review-is -->
### organization operating application under review is not doing — 1 rules

> If the organization operating the application under review is not doing the development or managing the development of the application, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222653` APSC-DV-003215 — The application development team must follow a set of coding standards.

</details>

<!-- id:prop:doing-development-or-managing-development-of-appli -->
### doing development or managing development of application — 1 rules

> If the organization operating the application is not doing the development or managing the development of the application, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222654` APSC-DV-003220 — The designer must create and update the Design Document for each release of the application.

</details>

<!-- id:prop:organization-operating-application-is-not-doing-de -->
### organization operating application is not doing development  — 1 rules

> If the organization operating the application is not doing the development or is not managing the development of the application, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222655` APSC-DV-003230 — Threat models must be documented and reviewed for each application release and updated as requi

</details>

<!-- id:prop:application-is-cots-application-and-development-te -->
### application is cots application and development team is not  — 1 rules

> If the application is a COTS application and the development team is not accessible to interview this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222657` APSC-DV-003236 — The application development team must provide an application incident response plan.

</details>

<!-- id:prop:process-classified-information -->
### process classified information — 1 rules

> If the application does not process classified information, this check is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222664` APSC-DV-003290 — If the application contains classified data, a Security Classification Guide must exist contain

</details>

<!-- id:prop:no-data-is-exported-to-test-or-development-databas -->
### no data is exported to test or development databases this ch — 1 rules

> If no data is exported to test or development databases, this check is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222666` APSC-DV-003310 — Production database exports must have database administration credentials and sensitive data re

</details>

<!-- id:prop:there-are-no-dos-threats-identified-in-threat-mode -->
### there are no dos threats identified in threat model requirem — 1 rules

> If there are no DoS threats identified in the threat model, the requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222667` APSC-DV-003320 — Protections against DoS attacks must be implemented.

</details>

<!-- id:prop:this-requirement-is-meant-to-be-applied-to-develop -->
### this requirement is meant to be applied to developers and de — 1 rules

> This requirement is meant to be applied to developers and development teams only, otherwise, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-222673` APSC-DV-003400 — The Program Manager must verify all levels of program management, designers, developers, and te

</details>

<!-- id:prop:process-classified-data -->
### process classified data — 1 rules

> If the application does not process classified data, this requirement is not applicable.

**Answer:** « state the fact about this system »

<details><summary>1 rules</summary>

- `V-265634` APSC-DV-002010 — The application must implement NSA-approved cryptography to protect classified information in a

</details>

---

## Part 2 — rules with NO N/A clause

147 rules. DISA offers no exemption, so each family needs its own answer.
**Expect the database and PKI families NOT to be N/A.**

<!-- id:fam:APSC-DV -->
### `APSC-DV` — 147 rules, **20 CAT I**

**Answer:** « does this family apply? if only partly, name the rules »

<details><summary>147 rules</summary>

- `V-222387` APSC-DV-000010 **[medium]** — The application must provide a capability to limit the number of logon sessions per user.
- `V-222388` APSC-DV-000060 **[medium]** — The application must clear temporary storage and cookies when the session is terminated.
- `V-222389` APSC-DV-000070 **[medium]** — The application must automatically terminate the non-privileged user session and log off non-pr
- `V-222390` APSC-DV-000080 **[medium]** — The application must automatically terminate the admin user session and log off admin users aft
- `V-222396` APSC-DV-000160 **[medium]** — The application must implement DoD-approved encryption to protect the confidentiality of remote
- `V-222397` APSC-DV-000170 **[medium]** — The application must implement cryptographic mechanisms to protect the integrity of remote acce
- `V-222407` APSC-DV-000280 **[medium]** — The application must provide automated mechanisms for supporting account management functions.
- `V-222412` APSC-DV-000330 **[medium]** — Unnecessary application accounts must be disabled, or deleted.
- `V-222423` APSC-DV-000440 **[medium]** — Application data protection requirements must be identified and documented.
- `V-222425` APSC-DV-000460 **[high]** — The application must enforce approved authorizations for logical access to information and syst
- `V-222429` APSC-DV-000500 **[medium]** — The application must prevent non-privileged users from executing privileged functions to includ
- `V-222430` APSC-DV-000510 **[high]** — The application must execute without excessive account permissions.
- `V-222431` APSC-DV-000520 **[medium]** — The application must audit the execution of privileged functions.
- `V-222432` APSC-DV-000530 **[high]** — The application must enforce the limit of three consecutive invalid logon attempts by a user du
- `V-222433` APSC-DV-000540 **[medium]** — The application administrator must follow an approved process to unlock locked user accounts.
- `V-222441` APSC-DV-000620 **[medium]** — The application must provide audit record generation capability for the creation of session IDs
- `V-222442` APSC-DV-000630 **[medium]** — The application must provide audit record generation capability for the destruction of session 
- `V-222443` APSC-DV-000640 **[medium]** — The application must provide audit record generation capability for the renewal of session IDs.
- `V-222444` APSC-DV-000650 **[medium]** — The application must not write sensitive data into the application logs.
- `V-222445` APSC-DV-000660 **[medium]** — The application must provide audit record generation capability for session timeouts.
- `V-222446` APSC-DV-000670 **[medium]** — The application must record a time stamp indicating when the event occurred.
- `V-222447` APSC-DV-000680 **[medium]** — The application must provide audit record generation capability for HTTP headers including User
- `V-222448` APSC-DV-000690 **[medium]** — The application must provide audit record generation capability for connecting system IP addres
- `V-222449` APSC-DV-000700 **[medium]** — The application must record the username or user ID of the user associated with the event.
- `V-222450` APSC-DV-000710 **[medium]** — The application must generate audit records when successful/unsuccessful attempts to grant priv
- `V-222451` APSC-DV-000720 **[medium]** — The application must generate audit records when successful/unsuccessful attempts to access sec
- `V-222452` APSC-DV-000730 **[medium]** — The application must generate audit records when successful/unsuccessful attempts to access sec
- `V-222454` APSC-DV-000750 **[medium]** — The application must generate audit records when successful/unsuccessful attempts to modify pri
- `V-222455` APSC-DV-000760 **[medium]** — The application must generate audit records when successful/unsuccessful attempts to modify sec
- `V-222456` APSC-DV-000770 **[medium]** — The application must generate audit records when successful/unsuccessful attempts to modify sec
- `V-222458` APSC-DV-000790 **[medium]** — The application must generate audit records when successful/unsuccessful attempts to delete pri
- `V-222459` APSC-DV-000800 **[medium]** — The application must generate audit records when successful/unsuccessful attempts to delete sec
- `V-222460` APSC-DV-000810 **[medium]** — The application must generate audit records when successful/unsuccessful attempts to delete app
- `V-222462` APSC-DV-000830 **[medium]** — The application must generate audit records when successful/unsuccessful logon attempts occur.
- `V-222463` APSC-DV-000840 **[medium]** — The application must generate audit records for privileged activities or other system-level acc
- `V-222464` APSC-DV-000850 **[medium]** — The application must generate audit records showing starting and ending time for user access to
- `V-222465` APSC-DV-000860 **[medium]** — The application must generate audit records when successful/unsuccessful accesses to objects oc
- `V-222468` APSC-DV-000910 **[medium]** — The application must initiate session auditing upon startup.
- `V-222469` APSC-DV-000940 **[medium]** — The application must log application shutdown events.
- `V-222471` APSC-DV-000960 **[medium]** — The application must log user actions involving access to data.
- `V-222472` APSC-DV-000970 **[medium]** — The application must log user actions involving changes to data.
- `V-222473` APSC-DV-000980 **[medium]** — The application must produce audit records containing information to establish when (date and t
- `V-222474` APSC-DV-000990 **[medium]** — The application must produce audit records containing enough information to establish which com
- `V-222476` APSC-DV-001010 **[medium]** — The application must produce audit records that contain information to establish the outcome of
- `V-222477` APSC-DV-001020 **[medium]** — The application must generate audit records containing information that establishes the identit
- `V-222478` APSC-DV-001030 **[medium]** — The application must generate audit records containing the full-text recording of privileged co
- `V-222479` APSC-DV-001040 **[medium]** — The application must implement transaction recovery logs when transaction based.
- `V-222482` APSC-DV-001080 **[medium]** — The application must be configured to write application logs to a centralized log repository.
- `V-222486` APSC-DV-001120 **[medium]** — The application must shut down by default upon audit failure (unless availability is an overrid
- `V-222497` APSC-DV-001250 **[medium]** — The applications must use internal system clocks to generate time stamps for audit records.
- `V-222498` APSC-DV-001260 **[medium]** — The application must record time stamps for audit records that can be mapped to Coordinated Uni
- `V-222500` APSC-DV-001280 **[medium]** — The application must protect audit information from any type of unauthorized read access.
- `V-222501` APSC-DV-001290 **[medium]** — The application must protect audit information from unauthorized modification.
- `V-222502` APSC-DV-001300 **[medium]** — The application must protect audit information from unauthorized deletion.
- `V-222511` APSC-DV-001410 **[medium]** — The application must enforce access restrictions associated with changes to application configu
- `V-222512` APSC-DV-001420 **[medium]** — The application must audit who makes configuration changes to the application.
- `V-222513` APSC-DV-001430 **[medium]** — The application must have the capability to prevent the installation of patches, service packs,
- `V-222514` APSC-DV-001440 **[medium]** — The applications must limit privileges to change the software resident within software librarie
- `V-222515` APSC-DV-001460 **[medium]** — An application vulnerability assessment must be conducted.
- `V-222518` APSC-DV-001500 **[medium]** — The application must be configured to disable non-essential capabilities.
- `V-222519` APSC-DV-001510 **[medium]** — The application must be configured to use only functions, ports, and protocols permitted to it 
- `V-222520` APSC-DV-001520 **[medium]** — The application must require users to reauthenticate when organization-defined circumstances or
- `V-222521` APSC-DV-001530 **[medium]** — The application must require devices to reauthenticate when organization-defined circumstances 
- `V-222523` APSC-DV-001550 **[medium]** — The application must use multifactor (Alt. Token) authentication for network access to privileg
- `V-222527` APSC-DV-001590 **[medium]** — The application must use multifactor (Alt. Token) authentication for local access to privileged
- `V-222532` APSC-DV-001640 **[medium]** — The application must utilize mutual authentication when endpoint device non-repudiation protect
- `V-222534` APSC-DV-001660 **[medium]** — Service-Oriented Applications handling non-releasable data must authenticate endpoint devices v
- `V-222548` APSC-DV-001795 **[medium]** — The application password must not be changeable by users other than the administrator or the us
- `V-222549` APSC-DV-001800 **[medium]** — The application must terminate existing user sessions upon account deletion.
- `V-222550` APSC-DV-001810 **[high]** — The application, when utilizing PKI-based authentication, must validate certificates by constru
- `V-222552` APSC-DV-001830 **[medium]** — The application must map the authenticated identity to the individual user or group account for
- `V-222554` APSC-DV-001850 **[high]** — The application must not display passwords/PINs as clear text.
- `V-222567` APSC-DV-001995 **[medium]** — The application must not be vulnerable to race conditions.
- `V-222568` APSC-DV-002000 **[medium]** — The application must terminate all network connections associated with a communications session
- `V-222570` APSC-DV-002020 **[medium]** — The application must utilize FIPS-validated cryptographic modules when signing application comp
- `V-222571` APSC-DV-002030 **[medium]** — The application must utilize FIPS-validated cryptographic modules when generating cryptographic
- `V-222572` APSC-DV-002040 **[medium]** — The application must utilize FIPS-validated cryptographic modules when protecting unclassified 
- `V-222574` APSC-DV-002150 **[medium]** — The application user interface must be either physically or logically separated from data stora
- `V-222575` APSC-DV-002210 **[medium]** — The application must set the HTTPOnly flag on session cookies.
- `V-222576` APSC-DV-002220 **[medium]** — The application must set the secure flag on session cookies.
- `V-222577` APSC-DV-002230 **[high]** — The application must not expose session IDs.
- `V-222578` APSC-DV-002240 **[high]** — The application must destroy the session ID value and/or cookie on logoff or browser close.
- `V-222579` APSC-DV-002250 **[medium]** — Applications must use system-generated session identifiers that protect against session fixatio
- `V-222580` APSC-DV-002260 **[medium]** — Applications must validate session identifiers.
- `V-222581` APSC-DV-002270 **[medium]** — Applications must not use URL embedded session IDs.
- `V-222582` APSC-DV-002280 **[medium]** — The application must not re-use or recycle session IDs.
- `V-222583` APSC-DV-002290 **[medium]** — The application must generate a unique session identifier using a FIPS 140-2/140-3 approved ran
- `V-222584` APSC-DV-002300 **[medium]** — The application must only allow the use of DoD-approved certificate authorities for verificatio
- `V-222585` APSC-DV-002310 **[high]** — The application must fail to a secure state if system initialization fails, shutdown fails, or 
- `V-222586` APSC-DV-002320 **[medium]** — In the event of a system failure, applications must preserve any information necessary to deter
- `V-222587` APSC-DV-002330 **[medium]** — The application must protect the confidentiality and integrity of stored information when requi
- `V-222590` APSC-DV-002360 **[medium]** — The application must isolate security functions from non-security functions.
- `V-222591` APSC-DV-002370 **[medium]** — The application must maintain a separate execution domain for each executing process.
- `V-222592` APSC-DV-002380 **[medium]** — Applications must prevent unauthorized and unintended information transfer via shared system re
- `V-222594` APSC-DV-002400 **[medium]** — The application must restrict the ability to launch Denial of Service (DoS) attacks against its
- `V-222596` APSC-DV-002440 **[high]** — The application must protect the confidentiality and integrity of transmitted information.
- `V-222597` APSC-DV-002450 **[medium]** — The application must implement cryptographic mechanisms to prevent unauthorized disclosure of i
- `V-222598` APSC-DV-002460 **[medium]** — The application must maintain the confidentiality and integrity of information during preparati
- `V-222599` APSC-DV-002470 **[medium]** — The application must maintain the confidentiality and integrity of information during reception
- `V-222600` APSC-DV-002480 **[medium]** — The application must not disclose unnecessary information to users.
- `V-222601` APSC-DV-002485 **[high]** — The application must not store sensitive information in hidden fields.
- `V-222602` APSC-DV-002490 **[high]** — The application must protect from Cross-Site Scripting (XSS) vulnerabilities.
- `V-222603` APSC-DV-002500 **[medium]** — The application must protect from Cross-Site Request Forgery (CSRF) vulnerabilities.
- `V-222604` APSC-DV-002510 **[high]** — The application must protect from command injection.
- `V-222605` APSC-DV-002520 **[medium]** — The application must protect from canonical representation vulnerabilities.
- `V-222606` APSC-DV-002530 **[medium]** — The application must validate all input.
- `V-222607` APSC-DV-002540 **[high]** — The application must not be vulnerable to SQL Injection.
- `V-222609` APSC-DV-002560 **[high]** — The application must not be subject to input handling vulnerabilities.
- `V-222610` APSC-DV-002570 **[medium]** — The application must generate error messages that provide information necessary for corrective 
- `V-222611` APSC-DV-002580 **[medium]** — The application must reveal error messages only to the ISSO, ISSM, or SA.
- `V-222612` APSC-DV-002590 **[high]** — The application must not be vulnerable to overflow attacks.
- `V-222613` APSC-DV-002610 **[medium]** — The application must remove organization-defined software components after updated versions hav
- `V-222614` APSC-DV-002630 **[medium]** — Security-relevant software updates and patches must be kept up to date.
- `V-222619` APSC-DV-002880 **[medium]** — The ISSO must ensure an account management process is implemented, verifying only authorized us
- `V-222621` APSC-DV-002900 **[medium]** — The ISSO must ensure application audit trails are retained for at least 30 months (12 months ac
- `V-222622` APSC-DV-002910 **[medium]** — The ISSO must review audit trails periodically based on system documentation recommendations or
- `V-222623` APSC-DV-002920 **[medium]** — The ISSO must report all suspected violations of IA policies in accordance with DoD information
- `V-222624` APSC-DV-002930 **[medium]** — The ISSO must ensure active vulnerability testing is performed.
- `V-222626` APSC-DV-002960 **[medium]** — The designer must ensure the application does not store configuration and control files in the 
- `V-222627` APSC-DV-002970 **[medium]** — The ISSO must ensure if a DoD STIG or NSA guide is not available, a third-party product will be
- `V-222628` APSC-DV-002980 **[medium]** — New IP addresses, data services, and associated ports used by the application must be submitted
- `V-222629` APSC-DV-002990 **[medium]** — The application must be registered with the DoD Ports and Protocols Database.
- `V-222634` APSC-DV-003030 **[medium]** — The application services and interfaces must be compatible with and ready for IPv6 networks.
- `V-222635` APSC-DV-003040 **[medium]** — The application must not be hosted on a general purpose machine if the application is designate
- `V-222636` APSC-DV-003050 **[medium]** — A contingency plan must exist in accordance with DOD policy based on the application's availabi
- `V-222637` APSC-DV-003060 **[medium]** — Recovery procedures and technical system features must exist so recovery is performed in a secu
- `V-222638` APSC-DV-003070 **[medium]** — Data backup must be performed at required intervals in accordance with DoD policy.
- `V-222639` APSC-DV-003080 **[medium]** — Back-up copies of the application software or source code must be stored in a fire-rated contai
- `V-222640` APSC-DV-003090 **[medium]** — Procedures must be in place to assure the appropriate physical and technical protection of the 
- `V-222642` APSC-DV-003110 **[high]** — The application must not contain embedded authentication data.
- `V-222643` APSC-DV-003120 **[high]** — The application must have the capability to mark sensitive/classified output when required.
- `V-222645` APSC-DV-003140 **[medium]** — Application files must be cryptographically hashed prior to deploying to DoD operational networ
- `V-222647` APSC-DV-003160 **[low]** — Test procedures must be created and at least annually executed to ensure system initialization,
- `V-222651` APSC-DV-003200 **[medium]** — The changes to the application must be assessed for IA and accreditation impact prior to implem
- `V-222656` APSC-DV-003235 **[medium]** — The application must not be subject to error handling vulnerabilities.
- `V-222658` APSC-DV-003240 **[high]** — All products must be supported by the vendor or the development team.
- `V-222659` APSC-DV-003250 **[high]** — The application must be decommissioned when maintenance or support is no longer available.
- `V-222660` APSC-DV-003260 **[low]** — Procedures must be in place to notify users when an application is decommissioned.
- `V-222661` APSC-DV-003270 **[medium]** — Unnecessary built-in application accounts must be disabled.
- `V-222662` APSC-DV-003280 **[high]** — Default passwords must be changed.
- `V-222663` APSC-DV-003285 **[medium]** — An Application Configuration Guide must be created and included with the application.
- `V-222665` APSC-DV-003300 **[medium]** — The designer must ensure uncategorized or emerging mobile code is not used in applications.
- `V-222668` APSC-DV-003330 **[medium]** — The system must alert an administrator when low resource conditions are encountered.
- `V-222669` APSC-DV-003340 **[low]** — At least one application administrator must be registered to receive update notifications, or s
- `V-222670` APSC-DV-003345 **[low]** — The application must provide notifications or alerts when product update and security related p
- `V-222671` APSC-DV-003350 **[medium]** — Connections between the DoD enclave and the Internet or other public or commercial wide area ne
- `V-222672` APSC-DV-003360 **[low]** — The application must generate audit records when concurrent logons from different workstations 

</details>

