FROM redmine:6.1

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/Winson-NoOT/redmine_mcp.git \
        plugins/redmine_mcp \
 && git clone --depth 1 https://github.com/Winson-NoOT/redmine_issue_update_statistics.git \
        plugins/redmine_issue_update_statistics

RUN bundle install

# Use DATABASE_URL instead of individual REDMINE_DB_* vars.
# Placed after bundle install so the entrypoint won't regenerate it.
COPY config/database.yml config/database.yml
