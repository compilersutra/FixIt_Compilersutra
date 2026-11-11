# Basic Terminology daily bot

Publishes **one beginner concept per day** from the Basic Terminology hub catalog.

## Local

```bash
python3 scripts/basic-terminology-bot/generate_daily_term.py
# or
bash scripts/basic-terminology-bot/run-all.sh
```

## Jenkins (production)

Job: `http://localhost:8080/job/compilersutra-basic-terminology-daily/`

- Cron: `15 8 * * *` (08:15 IST)
- Pipeline: `/home/aitr/compilersutra/jenkins_pipeline/Jenkinsfile.basic-terminology`
- Script: `/home/aitr/compilersutra/jenkins_pipeline/scripts/basic-terminology-daily/run-all.sh`

Keep `catalog.json` in sync with `src/data/basicTerminology/topics.js` (see skill `compilersutra-basic-terminology`).

Hub: https://www.compilersutra.com/docs/basic-terminology/
