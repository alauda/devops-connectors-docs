- [Summary](#summary)
- [Motivation](#motivation)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
  - [Use Cases](#use-cases)
  - [Requirements](#requirements)
- [Proposal](#proposal)
  - [Notes and Warnings](#notes-and-warnings)
- [Design Details](#design-details)
- [Design Evaluation](#design-evaluation)
  - [Reusability](#reusability)
  - [Simplicity](#simplicity)
  - [Flexibility](#flexibility)
  - [Conformance](#conformance)
  - [User Experience](#user-experience)
  - [Performance](#performance)
  - [Risks and Mitigations](#risks-and-mitigations)
  - [Drawbacks](#drawbacks)
- [Alternatives](#alternatives)
- [Implementation Plan](#implementation-plan)
  - [Test Plan](#test-plan)
  - [Infrastructure Needed](#infrastructure-needed)
  - [Upgrade and Migration Strategy](#upgrade-and-migration-strategy)
  - [Implementation Pull Requests](#implementation-pull-requests)
- [References](#references)

## Summary

This section is crucial for generating high-quality user documentation (e.g., release notes or development roadmaps). This information should be collected before implementation begins to avoid distracting the implementers while writing release notes and implementing features.

A good summary may be at least one paragraph long.

In this section and the following ones, please follow the [documentation style guide] guidelines. In particular, wrap lines to a reasonable length to allow reviewers to reference specific parts and reduce diffs when updating.

[Documentation Style Guide]: https://github.com/kubernetes/community/blob/master/contributors/guide/style-guide.md

## Motivation

This section explicitly lists the motivation, goals, and non-goals of this KEP. It describes the significance of the change and its benefits to users. The motivation section may optionally provide links to [experience reports] to demonstrate broader interest from the Tekton community in the KEP.

[Experience Reports]: https://github.com/golang/go/wiki/ExperienceReports

### Goals

- List the specific goals of the KEP.
- What is it trying to achieve?
- How will we know if it is successful?

### Non-Goals

- Listing non-goals helps to focus the discussion and make progress.
- What does this KEP not encompass?

### Use Cases

Describe the specific improvements that will be seen by specific user groups if the motivations in this document lead to fixes or features.

Consider the users’:
- [Roles] - Are they task authors? Catalog task users? Cluster administrators? Etc.
- Experiences - If the problem is resolved, which workflows or operations will be enhanced?

[Roles]: https://github.com/tektoncd/community/blob/main/user-profiles.md

### Requirements

Describe the constraints that the solution must satisfy, such as:
- What performance characteristics must be met?
- What specific edge cases must be handled?
- Which user scenarios will be impacted and must be accommodated?

## Proposal

This is where we specifically discuss the details of the proposal. There should be enough detail for reviewers to accurately understand your suggestion, but it should not include aspects like API design or implementation. The "Design Details" section below is for genuine detailed discussions.

### Notes and Warnings

(Optional)

Detail the necessary nuances here.
- What are the warnings regarding the proposal?
- What are some important details not mentioned above?
- What are the core concepts, and how are they related?

## Design Details

This section should contain enough information to make the specific details of your changes easy to understand. This might include API specifications (though not always required) or even code snippets. If there are any ambiguities about how to implement your proposal, this is the place to discuss them.

Add workflow diagrams or any relevant images if helpful, placing them under "/KEPs/images/". The file names should be chosen by the KEP authors, but a general guideline is that they should include at least the KEP number, e.g., "/KEPs/images/NNNN-workflow.jpg".

## Design Evaluation

How does this proposal impact Tekton's API conventions, reusability, simplicity, flexibility, and consistency, as discussed in the [design principles](https://github.com/tektoncd/community/blob/master/design-principles.md)?

### Reusability

- Are there existing functionalities related to the proposed feature? Is there reuse of existing functionalities?
- Is the problem addressed related to authoring time or runtime? Is the proposed feature at the appropriate level (authoring time or runtime)?

### Simplicity

- How does this proposal impact user experience?
- What is the current user experience without this feature? How challenging is it?
- How is the user experience after implementing the feature? What changes will occur?
- Does this proposal include the minimum changes needed to address the use case?
- Does the proposal have any implied behaviors? Will users expect these implied behaviors or be surprised by them? Are there any security risks?

### Flexibility

- What dependencies does this proposal require to function? What support or maintenance do these dependencies need?
- Are we coupling two or more Tekton projects in this proposal (e.g., coupling Pipelines with Chains)?
- Are we coupling Tekton with other projects (e.g., Knative, Sigstore)?
- What is the impact of this coupling on operators, such as maintenance and end-to-end testing?
- Are there opinionated choices in this proposal? If so, are they necessary? Can users extend it with their choices?

### Conformance

- Does this proposal require users to understand how the Tekton API is implemented?
- Does this proposal introduce additional Kubernetes concepts into the API? If so, is it necessary?
- If this proposal leads to changes in the API, what updates are needed for the [API specifications](https://github.com/tektoncd/pipeline/blob/main/docs/api-spec.md)?

### User Experience

(Optional)

Consider the impact on user experience. Depending on the area of change, users may be the authors of tasks and pipelines, those who may trigger TaskRuns and PipelineRuns, or those responsible for monitoring the execution through CLI, dashboards, or monitoring systems.

Consider including those working on CLI and dashboards.

### Performance

(Optional)

Consider the use cases affected by this change and their performance requirements.
- How does this change affect the startup and execution times of TaskRuns and PipelineRuns?
- What impact does it have on the Tekton controller and the resource usage of TaskRuns and PipelineRuns?

### Risks and Mitigations

What risks does this proposal present, and how can we mitigate them? Think broadly. For instance, consider security and how this will affect the larger Tekton ecosystem. Include considerations for those working outside of working groups or subprojects.
- How will security be reviewed, and by whom?
- How will user experience be reviewed, and by whom?

### Drawbacks

Why should this KEP not be implemented?

## Alternatives

What other approaches did you consider, and why were they excluded? These do not need to be as detailed as the proposal but should include enough information to convey the ideas and why they are unacceptable.

## Implementation Plan

What are the implementation phases or milestones? Taking an incremental approach makes it easier to review and merge implementation pull requests.

### Test Plan

When planning tests for this enhancement, consider the following:
- Will there be end-to-end and integration tests in addition to unit tests?
- How will it be tested in isolation versus being tested with other components?

There is no need to list all test cases; just outline the general strategy. Any aspects considered tricky about the implementation, as well as anything that may be particularly difficult to test, should be mentioned.

All code should have sufficient tests (with expected coverage eventually).

### Infrastructure Needed

(Optional)

Use this section if you need resources from the project or working group. Examples include new subprojects, requested repositories, or GitHub details. Listing these allows the working group to start the process for these resources immediately.

### Upgrade and Migration Strategy

(Optional)

Use this section to detail whether this feature requires upgrade or migration strategies. This is especially useful when we are modifying behaviors or adding features that may replace and deprecate current functionalities.

### Implementation Pull Requests

Once the KEP is ready to be marked as implemented, list all merged GitHub pull requests.

Note: This section is specifically for merged pull requests for this KEP. It will serve as a quick reference for those looking for the implementation of this KEP.

## References

(Optional)

Use this section to add links to GitHub issues, other KEPs, design documents in the Tekton shared drive, examples, etc. This is helpful for reviewing any other relevant links for more details.
