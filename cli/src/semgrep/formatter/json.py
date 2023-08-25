import json
from typing import Any
from typing import Iterable
from typing import Mapping
from typing import Sequence

import semgrep.semgrep_interfaces.semgrep_output_v1 as out
from semgrep import __VERSION__
from semgrep.error import SemgrepError
from semgrep.formatter.base import BaseFormatter
from semgrep.rule import Rule
from semgrep.rule_match import RuleMatch


# This is for converting instances of classes generated by atdpy, which
# all have a 'to_json' method.
def to_json(x: Any) -> Any:
    return x.to_json()


class JsonFormatter(BaseFormatter):
    @staticmethod
    def _rule_match_to_CliMatch(rule_match: RuleMatch) -> out.CliMatch:
        extra = out.CliMatchExtra(
            message=rule_match.message,
            metadata=out.RawJson(rule_match.metadata),
            severity=rule_match.severity.value,
            fingerprint=rule_match.match_based_id,
            # 'lines' already contains '\n' at the end of each line
            lines="".join(rule_match.lines).rstrip(),
            metavars=rule_match.match.extra.metavars,
            dataflow_trace=rule_match.dataflow_trace,
            engine_kind=rule_match.match.extra.engine_kind,
            validation_state=rule_match.match.extra.validation_state,
        )

        if rule_match.extra.get("sca_info"):
            extra.sca_info = rule_match.extra.get("sca_info")
        if rule_match.extra.get("fixed_lines"):
            extra.fixed_lines = rule_match.extra.get("fixed_lines")
        if rule_match.fix is not None:
            extra.fix = rule_match.fix
        if rule_match.fix_regex:
            extra.fix_regex = rule_match.fix_regex
        if rule_match.is_ignored is not None:
            extra.is_ignored = rule_match.is_ignored
        if rule_match.extra.get("extra_extra"):
            extra.extra_extra = out.RawJson(rule_match.extra.get("extra_extra"))

        return out.CliMatch(
            check_id=out.RuleId(rule_match.rule_id),
            path=out.Fpath(str(rule_match.path)),
            start=rule_match.start,
            end=rule_match.end,
            extra=extra,
        )

    def format(
        self,
        rules: Iterable[Rule],
        rule_matches: Iterable[RuleMatch],
        semgrep_structured_errors: Sequence[SemgrepError],
        cli_output_extra: out.CliOutputExtra,
        extra: Mapping[str, Any],
        is_ci_invocation: bool,
    ) -> str:
        # Note that extra is not used here! Every part of the JSON output should
        # be specified in semgrep_output_v1.atd and be part of CliOutputExtra
        output = out.CliOutput(
            version=out.Version(__VERSION__),
            results=[
                self._rule_match_to_CliMatch(rule_match) for rule_match in rule_matches
            ],
            errors=[error.to_CliError() for error in semgrep_structured_errors],
            paths=cli_output_extra.paths,
            time=cli_output_extra.time,
            explanations=cli_output_extra.explanations,
            skipped_rules=[],  # TODO: concatenate skipped_rules field from core responses
        )
        # Sort keys for predictable output. This helps with snapshot tests, etc.
        return json.dumps(output.to_json(), sort_keys=True, default=to_json)
